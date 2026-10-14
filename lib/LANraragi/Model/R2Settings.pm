package LANraragi::Model::R2Settings;
use v5.36;
use strict;
use warnings;
use utf8;
use Mojo::URL;
use LANraragi::Model::Config;

our %ENV_FIELDS = (
    enabled => 'LRR_R2_ENABLED', endpoint => 'LRR_R2_ENDPOINT', bucket => 'LRR_R2_BUCKET',
    access_key => 'LRR_R2_ACCESS_KEY_ID', secret_key => 'LRR_R2_SECRET_ACCESS_KEY',
    put_ttl => 'LRR_R2_PUT_TTL', get_ttl => 'LRR_R2_GET_TTL',
);
my ($cached, $cached_at);

sub managed_fields () {
    return { map { $_ => (defined $ENV{$ENV_FIELDS{$_}} && length $ENV{$ENV_FIELDS{$_}} ? 1 : 0) } keys %ENV_FIELDS };
}
sub saved_settings ($force = 0) {
    # Short cache is shared only within a process; other workers see edits within two seconds.
    if ($force || !$cached || time - $cached_at >= 2) {
        my $redis = LANraragi::Model::Config->get_redis_config;
        my %values = $redis->hgetall('LRR_R2_CONFIG');
        $redis->quit;
        $cached = \%values; $cached_at = time;
    }
    return { %$cached };
}
sub effective_settings ($saved) {
    my %values = (enabled => '0', endpoint => '', bucket => '', access_key => '', secret_key => '', put_ttl => 21600, get_ttl => 43200, %$saved);
    my $managed = managed_fields();
    for my $field (keys %ENV_FIELDS) { $values{$field} = $ENV{$ENV_FIELDS{$field}} if $managed->{$field}; }
    return \%values;
}
sub settings () {
    return effective_settings(saved_settings());
}
sub validate ($values) {
    die "R2 开关无效。\n" unless ($values->{enabled} // '') =~ /\A[01]\z/;
    if (length($values->{endpoint} // '')) {
        my $url = Mojo::URL->new($values->{endpoint});
        die "Endpoint 必须是 Cloudflare R2 的 HTTPS S3 地址，不含桶名、端口、路径或查询参数。\n"
          unless ($url->scheme // '') eq 'https' && ($url->host // '') =~ /\A[a-z0-9.-]+\.r2\.cloudflarestorage\.com\z/i
          && !defined($url->userinfo) && !length($url->query->to_string)
          && !defined($url->fragment) && $values->{endpoint} !~ m{:\d+(?:/|$)}
          && ($url->path->to_string eq '' || $url->path->to_string eq '/');
    }
    die "桶名须为 3–63 个小写字母、数字或连字符，首尾须为字母或数字。\n"
      if length($values->{bucket} // '') && $values->{bucket} !~ /\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\z/;
    for my $field (qw(access_key secret_key)) {
        die "访问密钥格式无效。\n" if length($values->{$field} // '') && $values->{$field} !~ /\A[\x21-\x7e]{1,256}\z/;
    }
    for my $field (qw(put_ttl get_ttl)) {
        die "链接有效期须为 60–604800 秒。\n" unless ($values->{$field} // '') =~ /\A\d+\z/ && $values->{$field} >= 60 && $values->{$field} <= 604800;
    }
    if ($values->{enabled} eq '1') {
        for my $field (qw(endpoint bucket access_key secret_key)) { die "启用 R2 前请填写 Endpoint、桶名和两项访问密钥。\n" unless length($values->{$field} // ''); }
    }
    return 1;
}
sub save_settings ($input) {
    my $saved = saved_settings();
    my $managed = managed_fields();
    for my $field (keys %ENV_FIELDS) {
        next if $managed->{$field};
        my $value = $input->{$field} // '';
        $value =~ s/\A\s+|\s+\z//g;
        next if ($field eq 'access_key' || $field eq 'secret_key') && !length($value);
        $saved->{$field} = $value;
    }
    validate(effective_settings($saved));
    my $redis = LANraragi::Model::Config->get_redis_config;
    # A single HSET replaces the supplied fields atomically and never logs credentials.
    $redis->hset('LRR_R2_CONFIG', map { ($_ => $saved->{$_}) } sort keys %$saved);
    $redis->quit;
    $cached = $saved; $cached_at = time;
    return 1;
}
1;
