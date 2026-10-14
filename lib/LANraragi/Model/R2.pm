package LANraragi::Model::R2;

use v5.36;
use strict;
use warnings;
use utf8;

use Digest::SHA qw(hmac_sha256 sha256_hex);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Promise;
use Mojo::DOM;
use Time::Piece;

use LANraragi::Model::Config;
use LANraragi::Model::R2Settings;

use Exporter 'import';
our @EXPORT_OK = qw(
  is_enabled create_upload_plan create_bundle_upload_plan sign_get_url verify_object put_manifest
  verify_objects
  get_archive_manifest save_archive_manifest make_batch_id
  delete_archive_objects delete_objects list_bucket_objects
);

sub is_enabled () {
    my $cfg = LANraragi::Model::R2Settings::settings();
    return $cfg->{enabled} eq '1' && $cfg->{endpoint} && $cfg->{bucket} && $cfg->{access_key} && $cfg->{secret_key};
}

sub config () {
    my $settings = LANraragi::Model::R2Settings::settings();
    die 'R2 未启用。' unless $settings->{enabled} eq '1';
    LANraragi::Model::R2Settings::validate($settings);
    my $endpoint = Mojo::URL->new($settings->{endpoint});
    die 'R2 Endpoint 必须是带主机名的 HTTPS URL。' unless $endpoint->scheme eq 'https' && $endpoint->host;
    return {
        endpoint => $endpoint,
        bucket => $settings->{bucket},
        access_key => $settings->{access_key},
        secret_key => $settings->{secret_key},
        put_ttl => bounded_ttl($settings->{put_ttl}, 21600),
        get_ttl => bounded_ttl($settings->{get_ttl}, 43200),
    };
}

sub bounded_ttl ( $value, $default ) {
    return $default unless defined $value && $value =~ /^\d+$/ && $value >= 60 && $value <= 604800;
    return 0 + $value;
}

sub make_batch_id () {
    open my $random, '<:raw', '/dev/urandom' or die 'Cannot open the system random source.';
    my $bytes = '';
    read $random, $bytes, 16;
    close $random;
    die 'Cannot read the system random source.' unless length($bytes) == 16;
    my $hex = unpack 'H*', $bytes;
    return substr($hex, 0, 8) . '-' . substr($hex, 8, 4) . '-4' . substr($hex, 13, 3)
      . '-a' . substr($hex, 17, 3) . '-' . substr($hex, 20, 12);
}

sub create_upload_plan ( $pages ) {
    my $cfg = config();
    my $batch = make_batch_id();
    my @uploads;
    my %extensions = ('image/jpeg' => 'jpg', 'image/png' => 'png', 'image/webp' => 'webp');
    for my $index ( 0 .. $#$pages ) {
        my $content_type = $pages->[$index]{contentType};
        die '不支持的页图格式。' unless $extensions{$content_type};
        my $key = sprintf 'reading/%s/pages/%06d.%s', $batch, $index + 1, $extensions{$content_type};
        push @uploads, {
            key => $key,
            size => 0 + $pages->[$index]{bytes},
            contentType => $content_type,
            url => presign('PUT', $key, $content_type, $cfg->{put_ttl}, $cfg),
        };
    }
    return { batchId => $batch, uploads => \@uploads };
}

sub create_bundle_upload_plan ( $size ) {
    my $cfg = config();
    my $batch = make_batch_id();
    my $key = "reading/$batch/book.bin";
    return { batchId => $batch, key => $key,
      url => presign('PUT', $key, 'application/octet-stream', $cfg->{put_ttl}, $cfg) };
}

sub sign_get_url ( $key ) {
    my $cfg = config();
    return presign('GET', $key, undef, $cfg->{get_ttl}, $cfg);
}

sub presign ( $method, $key, $content_type, $expires, $cfg, $extra_query = {} ) {
    my $now = gmtime;
    my $amz_date = $now->strftime('%Y%m%dT%H%M%SZ');
    my $date = $now->strftime('%Y%m%d');
    my $region = 'auto';
    my $service = 's3';
    my $scope = "$date/$region/$service/aws4_request";
    my $url = $cfg->{endpoint}->clone;
    my $host = $url->host;
    my $port = $url->port;
    $host .= ":$port" if defined $port && $port != 443;
    my $path = '/' . aws_encode($cfg->{bucket}) . '/' . join '/', map { aws_encode($_) } split m{/}, $key, -1;
    my %query = (
        %$extra_query,
        'X-Amz-Algorithm' => 'AWS4-HMAC-SHA256',
        'X-Amz-Credential' => "$cfg->{access_key}/$scope",
        'X-Amz-Date' => $amz_date,
        'X-Amz-Expires' => $expires,
        'X-Amz-SignedHeaders' => $content_type ? 'content-type;host' : 'host',
    );
    my $canonical_query = join '&', map { aws_encode($_) . '=' . aws_encode($query{$_}) } sort keys %query;
    my $canonical_headers = $content_type ? "content-type:$content_type\nhost:$host\n" : "host:$host\n";
    my $signed_headers = $content_type ? 'content-type;host' : 'host';
    my $canonical_request = join "\n", $method, $path, $canonical_query, $canonical_headers, $signed_headers, 'UNSIGNED-PAYLOAD';
    my $string_to_sign = join "\n", 'AWS4-HMAC-SHA256', $amz_date, $scope, sha256_hex($canonical_request);
    my $date_key = hmac_sha256($date, 'AWS4' . $cfg->{secret_key});
    my $region_key = hmac_sha256($region, $date_key);
    my $service_key = hmac_sha256($service, $region_key);
    my $signing_key = hmac_sha256('aws4_request', $service_key);
    $query{'X-Amz-Signature'} = unpack 'H*', hmac_sha256($string_to_sign, $signing_key);
    my $final_query = join '&', map { aws_encode($_) . '=' . aws_encode($query{$_}) } sort keys %query;
    my $origin = $url->scheme . '://' . $host;
    return $origin . $path . '?' . $final_query;
}

sub aws_encode ($value) {
    use bytes;
    $value =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;
    return $value;
}

sub verify_object ( $key, $expected_size, $expected_type ) {
    my $url = presign('HEAD', $key, undef, 300, config());
    my $response = Mojo::UserAgent->new->connect_timeout(15)->request_timeout(30)->head($url)->result;
    die "R2 对象检查返回 HTTP " . $response->code unless $response->is_success;
    my $size = $response->headers->content_length // -1;
    my $type = $response->headers->content_type // '';
    die 'R2 对象大小与上传计划不一致。' unless $size == $expected_size;
    die 'R2 对象的 Content-Type 与上传计划不一致。' unless lc($type) eq lc($expected_type);
    return { size => 0 + $size, contentType => $type };
}

# Verify bounded groups concurrently so a comic with dozens of pages does not
# spend several minutes waiting on one R2 HEAD round trip at a time.
sub verify_objects ( $objects, $concurrency = 4 ) {
    my @verified;
    my @pending = @$objects;
    my $ua = Mojo::UserAgent->new->connect_timeout(15)->request_timeout(45);
    while (@pending) {
        my @batch = splice @pending, 0, $concurrency;
        my @promises = map {
            my ($key, $size, $type) = @$_;
            $ua->head_p(presign('HEAD', $key, undef, 300, config()))
              ->then(sub ($tx) {
                  my $response = $tx->result;
                  die "R2 对象检查返回 HTTP " . $response->code unless $response->is_success;
                  my $got_size = $response->headers->content_length // -1;
                  my $got_type = $response->headers->content_type // '';
                  die 'R2 对象大小与上传计划不一致。' unless $got_size == $size;
                  die 'R2 对象的 Content-Type 与上传计划不一致。' unless lc($got_type) eq lc($type);
                  return { size => 0 + $got_size, contentType => $got_type };
              });
        } @batch;
        my @batch_verified;
        Mojo::Promise->all(@promises)->then(sub (@results) { @batch_verified = @results })->wait;
        push @verified, @batch_verified;
    }
    return \@verified;
}

sub put_manifest ( $key, $manifest ) {
    my $body = encode_json($manifest);
    my $url = presign('PUT', $key, 'application/json', 300, config());
    my $response = Mojo::UserAgent->new->connect_timeout(15)->request_timeout(30)
      ->put($url => { 'Content-Type' => 'application/json' } => $body)->result;
    die "R2 页面清单写入返回 HTTP " . $response->code unless $response->is_success;
    return 1;
}

sub get_archive_manifest ( $redis, $id ) {
    my $data = $redis->hget($id, 'r2_manifest');
    return unless defined $data && length $data;
    return decode_json($data);
}

# Keep the local manifest until remote deletion succeeds so failures can be
# retried from the same archive entry. Never accept keys outside its own batch.
sub delete_archive_objects ($manifest) {
    my $batch = $manifest->{batchId} // '';
    die 'R2 删除批次编号无效。' unless $batch =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}\z/;
    my $prefix = "reading/$batch/";
    my @keys;
    if ($manifest->{bundleKey}) {
        die 'R2 图包不属于此漫画，已停止删除。'
          unless $manifest->{bundleKey} eq "${prefix}book.bin";
        push @keys, $manifest->{bundleKey};
    } else {
        @keys = map { $_->{key} } @{$manifest->{pages} // []};
        push @keys, $manifest->{sourceKey} if $manifest->{sourceKey};
        for my $key (@keys) {
            die 'R2 对象不属于此漫画，已停止删除。'
              unless defined $key && $key =~ /\A\Q$prefix\E(?:pages\/[0-9]+\.(?:jpg|jpeg|png|webp)|source\.bin)\z/;
        }
    }
    delete_objects(\@keys);
    delete_objects(["${prefix}manifest.json"]);
    return scalar @keys + 1;
}

# S3 DELETE is idempotent. Check HEAD afterwards before dropping local records.
sub delete_objects ($keys, $concurrency = 4) {
    my %seen;
    my @pending = grep { !$seen{$_}++ } @$keys;
    my $cfg = config();
    my $ua = Mojo::UserAgent->new->connect_timeout(15)->request_timeout(45);
    while (@pending) {
        my @group = splice @pending, 0, $concurrency;
        my @promises = map {
            my $key = $_;
            $ua->delete_p(presign('DELETE', $key, undef, 300, $cfg))->then(sub ($tx) {
                die 'R2 删除请求失败（HTTP ' . ($tx->result->code // 'network') . '）。'
                  unless $tx->result->is_success || ($tx->result->code // 0) == 404;
                return $ua->head_p(presign('HEAD', $key, undef, 300, $cfg));
            })->then(sub ($tx) {
                die 'R2 删除后的对象校验失败，请重试删除。' unless ($tx->result->code // 0) == 404;
                return 1;
            });
        } @group;
        my $failure;
        Mojo::Promise->all(@promises)->catch(sub ($error) { $failure = $error })->wait;
        die $failure if defined $failure;
    }
    return scalar keys %seen;
}

sub list_bucket_objects () {
    my @objects;
    my $token;
    my $cfg = config();
    my $ua = Mojo::UserAgent->new->connect_timeout(15)->request_timeout(45);
    do {
        my %query = ('list-type' => '2', 'max-keys' => '1000');
        $query{'continuation-token'} = $token if defined $token;
        my $res = $ua->get(presign('GET', '', undef, 300, $cfg, \%query))->result;
        die 'R2 桶列表读取失败。' unless $res->is_success;
        my $xml = Mojo::DOM->new->xml(1)->parse($res->body);
        for my $item ($xml->find('Contents')->each) {
            push @objects, { key => $item->at('Key')->text, size => 0 + $item->at('Size')->text };
        }
        $token = $xml->at('NextContinuationToken') ? $xml->at('NextContinuationToken')->text : undef;
        die 'R2 桶列表缺少分页游标。' if $xml->at('IsTruncated') && $xml->at('IsTruncated')->text eq 'true' && !defined $token;
    } while (defined $token);
    return \@objects;
}

sub save_archive_manifest ( $redis, $id, $manifest ) {
    $redis->hset($id, 'r2_manifest', encode_json($manifest));
    $redis->hset($id, 'pagecount', scalar @{$manifest->{pages}});
    my $total_bytes = 0;
    $total_bytes += $_->{bytes} // 0 for @{$manifest->{pages}};
    $redis->hset($id, 'arcsize', $total_bytes);
}

1;
