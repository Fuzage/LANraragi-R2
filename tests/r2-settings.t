use v5.36;
use utf8;
use Test::More;
use LANraragi::Model::R2Settings;

{
    package R2FakeRedis;
    sub new { bless { data => {} }, shift }
    sub hgetall { %{$_[0]{data}} }
    sub hset { my ($self, $key, @pairs) = @_; my %pairs = @pairs; @{$self->{data}}{keys %pairs} = values %pairs; 1 }
    sub quit { 1 }
}
local %ENV = %ENV;
delete @ENV{values %LANraragi::Model::R2Settings::ENV_FIELDS};
my $redis = R2FakeRedis->new;
no warnings 'redefine';
local *LANraragi::Model::Config::get_redis_config = sub { $redis };
my %input = (enabled => '1', endpoint => 'https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com',
    bucket => 'example-comics', access_key => 'example-access', secret_key => 'example-secret', put_ttl => 21600, get_ttl => 43200);

is(LANraragi::Model::R2Settings::settings()->{enabled}, '0', 'R2 off on first start');
ok(LANraragi::Model::R2Settings::save_settings(\%input), 'complete web settings saved');
is(LANraragi::Model::R2Settings::settings()->{bucket}, 'example-comics', 'stored config used');
my %blank = (%input, access_key => '', secret_key => '');
LANraragi::Model::R2Settings::save_settings(\%blank);
is(LANraragi::Model::R2Settings::settings()->{secret_key}, 'example-secret', 'blank secret preserves existing key');
is(LANraragi::Model::R2Settings::settings()->{access_key}, 'example-access', 'blank access ID preserves existing key');
{
    local $ENV{LRR_R2_BUCKET} = 'environment-comics';
    is(LANraragi::Model::R2Settings::settings()->{bucket}, 'environment-comics', 'environment wins over web config');
    is(LANraragi::Model::R2Settings::managed_fields()->{bucket}, 1, 'managed field identified');
    my %attempt = (%blank, bucket => 'ignored-bucket');
    LANraragi::Model::R2Settings::save_settings(\%attempt);
}
is(LANraragi::Model::R2Settings::settings()->{bucket}, 'example-comics', 'web edit does not change managed bucket');
{
    local $ENV{LRR_R2_ENABLED} = '0';
    is(LANraragi::Model::R2Settings::settings()->{enabled}, '0', 'environment zero disables R2');
}
for my $bad (
    { endpoint => 'http://example.r2.cloudflarestorage.com' },
    { endpoint => 'https://example.r2.cloudflarestorage.com/path' },
    { endpoint => 'https://example.r2.cloudflarestorage.com?secret=1' },
    { endpoint => 'https://localhost' },
    { bucket => '../invalid' }, { bucket => 'invalid.bucket' }, { get_ttl => 59 }, { put_ttl => 604801 }, { secret_key => "bad\nkey" }
) {
    my %values = (%input, %$bad);
    ok(!eval { LANraragi::Model::R2Settings::validate(\%values); 1 }, 'invalid setting rejected');
}
my %bad_save = (%input, bucket => '../invalid');
ok(!eval { LANraragi::Model::R2Settings::save_settings(\%bad_save); 1 }, 'failed validation rejects save');
is($redis->{data}{bucket}, 'example-comics', 'rejected save does not modify persisted settings');
LANraragi::Model::R2Settings::save_settings({ %blank, enabled => '0' });
is(LANraragi::Model::R2Settings::settings()->{enabled}, '0', 'web switch can disable R2');
is(LANraragi::Model::R2Settings::settings()->{secret_key}, 'example-secret', 'disabling preserves credentials');
{
    local $ENV{LRR_R2_BUCKET} = '';
    is(LANraragi::Model::R2Settings::settings()->{bucket}, 'example-comics', 'empty compose value falls back to web');
}
done_testing;
