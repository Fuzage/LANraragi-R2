package LANraragi::Controller::R2Settings;
use v5.36;
use utf8;
use Mojo::Base 'Mojolicious::Controller';
use LANraragi::Model::R2;
use LANraragi::Model::R2Settings;
use LANraragi::Utils::Generic qw(generate_themes_header);

sub index ($self) {
    LANraragi::Model::R2Settings::saved_settings(1);
    my $settings = LANraragi::Model::R2Settings::settings();
    # Credentials never go into a template, JSON response or a log.
    my %public = map { $_ => $settings->{$_} } qw(enabled endpoint bucket put_ttl get_ttl);
    $public{access_saved} = length($settings->{access_key}) ? 1 : 0;
    $public{secret_saved} = length($settings->{secret_key}) ? 1 : 0;
    my $csrf = $self->session('r2_csrf') // LANraragi::Model::R2::make_batch_id();
    $self->session(r2_csrf => $csrf);
    $self->res->headers->cache_control('no-store');
    $self->render(template => 'r2_settings', title => 'R2 存储设置', version => $self->LRR_VERSION,
        csshead => generate_themes_header($self), r2 => \%public,
        managed => LANraragi::Model::R2Settings::managed_fields(), csrf => $csrf);
}
sub valid_csrf ($self) {
    my $expected = $self->session('r2_csrf') // '';
    return 1 if length($expected) && ($self->req->param('csrf') // '') eq $expected;
    $self->render(json => { success => 0, message => '页面会话已过期，请刷新后重试。' }, status => 403);
    return 0;
}
sub save ($self) {
    return unless valid_csrf($self);
    my %input = map { $_ => scalar($self->req->param($_)) } keys %LANraragi::Model::R2Settings::ENV_FIELDS;
    my $ok = eval { LANraragi::Model::R2Settings::save_settings(\%input); 1 };
    my $error = $@;
    $error = $error =~ /\A((?:R2 开关|Endpoint|桶名|访问密钥|链接有效期|启用 R2)[^\n]*)/ ? $1 : '无法保存 R2 设置，请检查数据库连接。';
    $self->res->headers->cache_control('no-store');
    $self->render(json => { success => $ok ? 1 : 0, message => $ok ? 'R2 设置已保存，工作进程会在约 2 秒内更新。' : ($error || '无法保存 R2 设置。') });
}
sub check ($self) {
    return unless valid_csrf($self);
    LANraragi::Model::R2Settings::saved_settings(1);
    my $cfg;
    eval { $cfg = LANraragi::Model::R2::config(); 1 } or return $self->render(json => { success => 0, message => '请先保存完整的配置并启用 R2。' });
    my $url = LANraragi::Model::R2::presign('GET', '', undef, 60, $cfg, { 'list-type' => '2', 'max-keys' => '1' });
    $self->render_later;
    Mojo::UserAgent->new->connect_timeout(10)->request_timeout(20)->max_response_size(65536)->get_p($url)->then(sub ($tx) {
        my $res = $tx->result;
        my $ok = $res->is_success;
        $self->render(json => { success => $ok ? 1 : 0, message => $ok ? '连接成功，已确认可以读取该桶。请继续配置 CORS，并用一本漫画验证上传和阅读。' : '连接失败（HTTP ' . ($res->code // 0) . '）。请检查 Endpoint、桶名、密钥和该桶的读写权限。' });
    })->catch(sub ($error) {
        $self->render(json => { success => 0, message => '无法连接 R2，请检查 Endpoint 和服务器网络。' });
    });
}
1;
