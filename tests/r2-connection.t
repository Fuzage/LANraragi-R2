use v5.36;
use utf8;
use Test::More;
use Test::Mojo;
use Mojolicious;
use Mojo::IOLoop;
use LANraragi::Controller::R2Settings;

my $app = Mojolicious->new;
$app->secrets(['connection-test-only']);
$app->routes->namespaces(['LANraragi::Controller']);
$app->routes->get('/session')->to(cb => sub ($c) {
    $c->session(r2_csrf => 'test-csrf');
    $c->render(text => 'ready');
});
$app->routes->post('/check')->to('r2_settings#check');
my $status = 200;
$app->routes->get('/bucket')->to(cb => sub ($c) {
    $c->render_later;
    Mojo::IOLoop->timer(0.05 => sub {
        $c->render(status => $status, text => $status == 200
            ? '<ListBucketResult/>' : '<Error><Code>AccessDenied</Code></Error>');
    });
});
my $t = Test::Mojo->new($app);
my $url = $t->ua->server->url->clone->path('/bucket');
no warnings 'redefine';
local *LANraragi::Model::R2Settings::saved_settings = sub { {} };
local *LANraragi::Model::R2::config = sub { {} };
local *LANraragi::Model::R2::presign = sub { $url };
$t->get_ok('/session')->status_is(200);
$t->post_ok('/check' => form => { csrf => 'test-csrf' })
    ->status_is(200)->json_is('/success' => 1);
$status = 403;
$t->post_ok('/check' => form => { csrf => 'test-csrf' })
    ->status_is(200)->json_is('/success' => 0)
    ->json_like('/message' => qr/HTTP 403/);
$url = Mojo::URL->new('http://127.0.0.1:1/?X-Amz-Signature=do-not-expose');
$t->post_ok('/check' => form => { csrf => 'test-csrf' })
    ->status_is(200)->json_is('/success' => 0)
    ->content_unlike(qr/do-not-expose|X-Amz/);
local *LANraragi::Model::R2::config = sub { die 'incomplete configuration' };
$t->post_ok('/check' => form => { csrf => 'test-csrf' })
    ->status_is(200)->json_is('/success' => 0);
$t->post_ok('/check' => form => { csrf => 'wrong' })->status_is(403);
done_testing;
