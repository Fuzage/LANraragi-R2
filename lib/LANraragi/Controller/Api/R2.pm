package LANraragi::Controller::Api::R2;

use v5.36;
use Mojo::Base 'Mojolicious::Controller';

use File::Basename qw(basename);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Encode qw(encode);
use Mojo::JSON qw(encode_json decode_json);
use Scalar::Util qw(looks_like_number);
use Time::Piece;

use LANraragi::Model::Config;
use LANraragi::Model::R2 qw(is_enabled create_upload_plan create_bundle_upload_plan verify_object verify_objects put_manifest save_archive_manifest make_batch_id);
use LANraragi::Model::Upload;
use LANraragi::Utils::Archive qw(extract_single_file);
use LANraragi::Utils::Path qw(get_archive_path);

sub plan {
    my $self = shift;
    return $self->render(json => { success => 0, error => '此 LANraragi 测试实例尚未启用 R2。' }, status => 503) unless is_enabled();

    my $body = $self->req->json || {};
    my $pages = $body->{pages};
    my $total = 0;
    if (($body->{mode} // '') eq 'bundle') {
        unless (valid_int($body->{bytes}, 1, 5 * 1024 * 1024 * 1024)) {
            return $self->render(json => { success => 0, error => '图包大小无效。' }, status => 400);
        }
        $total = 0 + $body->{bytes};
    } else {
        unless (ref($pages) eq 'ARRAY' && @$pages >= 1 && @$pages <= 500) {
            return $self->render(json => { success => 0, error => '页面列表无效。' }, status => 400);
        }
        for my $page (@$pages) {
            unless (ref($page) eq 'HASH' && valid_int($page->{bytes}, 1, 100 * 1024 * 1024)
                && defined $page->{contentType} && $page->{contentType} =~ /\Aimage\/(?:jpeg|png|webp)\z/) {
                return $self->render(json => { success => 0, error => '页图格式或大小无效。' }, status => 400);
            }
            $total += $page->{bytes};
        }
    }
    if ($total > 5 * 1024 * 1024 * 1024) {
        return $self->render(json => { success => 0, error => '单次上传总量不能超过 5 GiB。' }, status => 413);
    }

    my $plan;
    eval {
        if (($body->{mode} // '') eq 'bundle') {
          $plan = create_bundle_upload_plan($total);
        } else {
          $plan = create_upload_plan([map {{ bytes => 0 + $_->{bytes}, contentType => $_->{contentType} }} @$pages]);
        }
        my $batch = {
            state => 'pending',
            batchId => $plan->{batchId},
            bundleKey => $plan->{key}, bundleBytes => $total,
            pages => [map {{
                key => $plan->{uploads}[$_]{key},
                size => 0 + $pages->[$_]{bytes},
                contentType => $pages->[$_]{contentType},
            }} (ref($pages) eq 'ARRAY' ? (0 .. $#$pages) : ())],
            createdAt => gmtime->datetime . 'Z',
        };
        my $redis = LANraragi::Model::Config->get_redis;
        $redis->setex('LRR_R2_BATCH:' . $plan->{batchId}, 30 * 3600, encode_json($batch));
        $redis->quit;
        1;
    } or do {
        my $error = $@ || 'Unknown R2 signing error.';
        $self->LRR_LOGGER->error("R2 upload plan failed: $error");
        return $self->render(json => { success => 0, error => '无法生成 R2 上传链接，请检查 VPS 配置和日志。' }, status => 500);
    };
    return $self->render(json => { success => 1, %$plan });
}

sub finalize {
    my $self = shift;
    return $self->render(json => { success => 0, error => '此 LANraragi 测试实例尚未启用 R2。' }, status => 503) unless is_enabled();

    my $batch_id = $self->req->param('batchId') // '';
    return $self->render(json => { success => 0, error => '上传批次编号无效。' }, status => 400)
      unless $batch_id =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}\z/;

    my $redis = LANraragi::Model::Config->get_redis;
    my $batch_json = $redis->get('LRR_R2_BATCH:' . $batch_id);
    unless ($batch_json) {
        $redis->quit;
        return $self->render(json => { success => 0, error => '上传批次已过期或不存在，请重新开始上传。' }, status => 410);
    }
    my $batch = decode_json($batch_json);
    if ($batch->{state} eq 'complete' && $batch->{archiveId}) {
        $redis->quit;
        return $self->render(json => { success => 1, archiveId => $batch->{archiveId}, title => $batch->{title}, idempotent => 1 });
    }
    my $lock_key = 'LRR_R2_FINALIZE_LOCK:' . $batch_id;
    unless ($redis->setnx($lock_key, '1')) {
        $redis->quit;
        return $self->render(json => { success => 0, error => '该批次正在完成校验，请稍后刷新书库。' }, status => 409);
    }
    $redis->expire($lock_key, 1800);
    $redis->quit;

    my $success = 0;
    my $result;
    eval {
        my $manifest_json = $self->req->param('manifest') // '';
        die '页面清单缺失或超过大小限制。' if length($manifest_json) < 2 || length($manifest_json) > 1024 * 1024;
        # Mojolicious has already decoded multipart text fields to Perl characters.
        # Mojo::JSON::decode_json expects UTF-8 bytes, so encode before parsing
        # non-ASCII page names and source filenames.
        my $manifest = decode_json(encode('UTF-8', $manifest_json));
        die '页面清单与上传计划不匹配。'
          unless ref($manifest->{pages}) eq 'ARRAY'
            && (!@{$batch->{pages}} || @{$manifest->{pages}} == @{$batch->{pages}});
        die '原文件名无效。' unless defined $manifest->{sourceName} && !ref($manifest->{sourceName}) && length($manifest->{sourceName}) <= 500;

        die '图包信息与上传计划不匹配。'
          unless ($manifest->{bundleKey} // '') eq ($batch->{bundleKey} // '')
            && ($manifest->{bundleBytes} // -1) == ($batch->{bundleBytes} // -2);
        my $bundle_check = verify_object($batch->{bundleKey}, $batch->{bundleBytes}, 'application/octet-stream');
        my @verified_pages;
        my $expected_offset = 0;
        die '页面清单无效。' unless ref($manifest->{pages}) eq 'ARRAY' && @{$manifest->{pages}} >= 1 && @{$manifest->{pages}} <= 500;
        for my $index (0 .. $#{$manifest->{pages}}) {
            my $page = $manifest->{pages}[$index];
            die '页面尺寸无效。' unless valid_int($page->{width}, 1, 50000) && valid_int($page->{height}, 1, 50000);
            die '页面偏移或大小无效。' unless valid_int($page->{offset}, 0, $batch->{bundleBytes})
              && valid_int($page->{bytes}, 1, $batch->{bundleBytes}) && $page->{offset} == $expected_offset;
            die '页图格式无效。' unless ($page->{contentType} // '') =~ /\Aimage\/(?:jpeg|png|webp)\z/;
            die '页面内容超过图包大小。' if $page->{offset} + $page->{bytes} > $batch->{bundleBytes};
            $expected_offset += $page->{bytes};
            push @verified_pages, {
                index => $index + 1,
                name => safe_page_name($page->{name}),
                offset => 0 + $page->{offset},
                contentType => $page->{contentType},
                width => 0 + $page->{width},
                height => 0 + $page->{height},
                bytes => 0 + $page->{bytes},
            };
        }
        die '图包总长度与页面清单不一致。' unless $expected_offset == $batch->{bundleBytes};

        my $stub = $self->req->upload('stub');
        die '缺少 LANraragi 描述包。' unless $stub;
        die '描述包超过 32 MiB 限制。' if $stub->size > 32 * 1024 * 1024;

        my $source_name = safe_source_name($manifest->{sourceName});
        my $archive_title = $source_name;
        $archive_title =~ s/\.[^.]+\z//;
        my $tmpdir = tempdir(CLEANUP => 1);
        # The temporary filesystem path does not need the user's Unicode filename.
        my $stub_path = "$tmpdir/" . substr($batch_id, 0, 8) . '.cbz';
        die '无法保存本地描述包。' unless $stub->move_to($stub_path);

        my $final_manifest = {
            schema => 'lanraragi-r2-reading/v1',
            state => 'ready',
            batchId => $batch_id,
            bundleKey => $batch->{bundleKey},
            bundleBytes => $bundle_check->{size},
            sourceName => $manifest->{sourceName},
            sourceBytes => 0,
            createdAt => gmtime->datetime . 'Z',
            losslessPages => Mojo::JSON::true,
            pages => \@verified_pages,
        };
        put_manifest("reading/$batch_id/manifest.json", $final_manifest);

        my $category_id = $self->req->param('categoryId');
        my ($status, $archive_id, $title, $message) = LANraragi::Model::Upload::handle_incoming_file(
            $stub_path, $category_id, undef, $archive_title, undef, 1
        );
        die "LANraragi could not create the archive record: $message" unless $status == 200;
        # Upload's return value names the temporary descriptor; the library
        # already stores the explicit source title supplied above.
        $title = $archive_title;

        my $archive_redis = LANraragi::Model::Config->get_redis;
        save_archive_manifest($archive_redis, $archive_id, $final_manifest);
        my $archive_path = get_archive_path($archive_redis, $archive_id);
        $archive_redis->quit;
        write_page_thumbnails($archive_id, $archive_path, scalar @verified_pages);

        my $batch_redis = LANraragi::Model::Config->get_redis;
        $batch->{state} = 'complete';
        $batch->{archiveId} = $archive_id;
        $batch->{title} = $title;
        $batch_redis->setex('LRR_R2_BATCH:' . $batch_id, 30 * 86400, encode_json($batch));
        $batch_redis->del($lock_key);
        $batch_redis->quit;
        $success = 1;
        $result = { success => 1, archiveId => $archive_id, title => $title };
        1;
    } or do {
        my $error = $@ || 'Unknown R2 finalize error.';
        $self->LRR_LOGGER->error("R2 upload finalization failed for $batch_id: $error");
        my $lock_redis = LANraragi::Model::Config->get_redis;
        $lock_redis->del($lock_key);
        $lock_redis->quit;
        return $self->render(json => { success => 0, error => "页图已上传，但 R2 校验或 LANraragi 登记失败：$error" }, status => 502);
    };

    return $self->render(json => $result);
}

sub valid_int ( $value, $minimum, $maximum ) {
    return defined $value && looks_like_number($value) && $value =~ /\A\d+\z/ && $value >= $minimum && $value <= $maximum;
}

sub safe_page_name ($name) {
    return 'page' unless defined $name;
    $name =~ s/[\r\n\x00-\x1f]//g;
    return substr($name, 0, 500);
}

sub safe_source_name ($name) {
    $name = basename($name // 'remote-comic');
    $name =~ s/[\x00-\x1f\\\/]+/_/g;
    $name =~ s/\.+\z//;
    $name = substr($name, 0, 180);
    return $name || 'remote-comic';
}

sub write_page_thumbnails ( $id, $archive, $count ) {
    my $thumbdir = LANraragi::Model::Config->get_thumbdir;
    my $subfolder = substr($id, 0, 2);
    my $pagedir = "$thumbdir/$subfolder/$id";
    make_path($pagedir);
    for my $page (1 .. $count) {
        my $entry = sprintf '__r2_thumbs/%06d.jpg', $page;
        my $bytes = extract_single_file($archive, $entry);
        die "A local thumbnail is missing for page $page." unless defined $bytes && length($bytes);
        my $path = sprintf '%s/%d.jpg', $pagedir, $page;
        open my $fh, '>:raw', $path or die "Cannot write page thumbnail: $!";
        print {$fh} $bytes;
        close $fh or die "Cannot finish writing page thumbnail: $!";
    }
}

1;
