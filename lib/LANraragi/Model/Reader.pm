package LANraragi::Model::Reader;

use v5.36;
use experimental 'try';

use strict;
use warnings;
use utf8;

use Redis;
use File::Basename;
use File::Path qw(remove_tree make_path);
use File::Find qw(find);
use File::Copy qw(move);
use Mojo::JSON qw(encode_json);
use Data::Dumper;
use URI::Escape;

use LANraragi::Utils::Generic qw(is_image);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Archive qw(get_filelist);
use LANraragi::Utils::Redis   qw(redis_decode);
use LANraragi::Utils::Resizer qw(get_resizer);
use LANraragi::Utils::Path    qw(get_archive_path);
use LANraragi::Model::R2      qw(is_enabled sign_get_url get_archive_manifest);

our $resampler = get_resizer();

# resize_image(image,quality, size_threshold)
# Convert an image to a cheaper on bandwidth format.
# This will no-op if no resizer is available.
sub resize_image ( $content, $quality, $threshold ) {

    #Is the file size higher than the threshold?
    if ( ( ( length($content) / 1024 * 10 ) / 10 ) > $threshold ) {
        my $resized = $resampler->resize_page( $content, $quality, "jpg" );
        if ( defined($resized) ) {
            return $resized;
        }
    }
    return $content;
}

# build_reader_JSON(mojo, id, forceReload)
# Opens the archive specified by its ID, and returns a json containing the page names.
sub build_reader_JSON ( $self, $id, $force ) {

    # Get the path from Redis.
    # Filenames are stored as they are on the OS, so no decoding!
    my $redis   = LANraragi::Model::Config->get_redis;
    my $archive = get_archive_path( $redis, $id );

    # Remote archives keep a tiny local descriptor for LANraragi metadata and
    # thumbnails. Their ordered reading pages are served directly from R2.
    my $remote_manifest = get_archive_manifest($redis, $id);
    if ( $remote_manifest && $remote_manifest->{state} eq 'ready' ) {
        die 'R2 page delivery is disabled or not configured.' unless is_enabled();
        if ($remote_manifest->{bundleKey}) {
            my $url = sign_get_url($remote_manifest->{bundleKey});
            my @ranges = map {{ offset => 0 + $_->{offset}, bytes => 0 + $_->{bytes},
              name => $_->{name}, contentType => $_->{contentType} }} @{$remote_manifest->{pages}};
            $redis->hset( $id, 'pagecount', scalar @ranges );
            $redis->quit();
            return { pages => [map { $url } @ranges], ranges => \@ranges, r2Bundle => 1 };
        }
        my @remote_pages = map { sign_get_url($_->{key}) } @{$remote_manifest->{pages}};
        $redis->hset( $id, 'pagecount', scalar @remote_pages );
        $redis->quit();
        return { pages => \@remote_pages, r2 => 1 };
    }

    # Parse archive to get its list of images
    my @images = get_filelist($archive, $id);

    $self->LRR_LOGGER->debug( "Files found in archive (encoding might be incorrect): \n " . Dumper @images );

    # Build a browser-compliant filepath array from @images
    my @images_browser;

    foreach my $imgpath (@images) {

        # Since we're using uri_escape_utf8 for escaping, we need to make sure the path is valid UTF8.
        # The good ole' redis_decode allows us to make sure of that.
        $imgpath = redis_decode($imgpath);

        # We need to sanitize the image's path, in case the folder contains illegal characters,
        # but uri_escape would also nuke the / needed for navigation. Let's solve this with a quick regex search&replace.
        # First, we encode all HTML characters...
        $imgpath = uri_escape_utf8($imgpath);

        # Then we bring the slashes back.
        $imgpath =~ s!%2F!/!g;

        # Bundle this path into an API call which will be used by the browser
        push @images_browser, $self->url_for("/api/archives/$id/page?path=$imgpath")->path_query;
    }

    # Update pagecount and sizes
    $redis->hset( $id, "pagecount", scalar @images );
    $redis->quit();

    return { pages => \@images_browser, };
}

1;
