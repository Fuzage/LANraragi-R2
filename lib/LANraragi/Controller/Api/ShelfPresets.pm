package LANraragi::Controller::Api::ShelfPresets;

use v5.36;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(encode_json decode_json);
use Time::Piece;
use Time::HiRes qw(gettimeofday);
use LANraragi::Model::Config;

my $KEY = 'LRR_LANR2DER_SHELF_PRESETS';

sub _timestamp () {
    my ($seconds, $microseconds) = gettimeofday();
    return gmtime($seconds)->datetime . sprintf('.%06dZ', $microseconds);
}

sub _all ($self) {
    my $redis = LANraragi::Model::Config->get_redis;
    my %raw = $redis->hgetall($KEY);
    $redis->quit;
    my @items;
    for my $value (values %raw) {
        my $item = eval { decode_json($value) };
        push @items, $item if ref($item) eq 'HASH';
    }
    return @items;
}

sub _valid_nodes ($nodes) {
    return 0 unless ref($nodes) eq 'ARRAY' && @$nodes <= 5000;
    my $count = 0;
    my $walk;
    $walk = sub ($list, $depth) {
        return 0 if $depth > 16;
        for my $node (@$list) {
            return 0 unless ref($node) eq 'HASH';
            return 0 unless defined $node->{id} && !ref($node->{id}) && length($node->{id}) <= 200;
            return 0 unless defined $node->{kind} && ($node->{kind} eq 'book' || $node->{kind} eq 'folder');
            return 0 unless defined $node->{name} && !ref($node->{name}) && length($node->{name}) <= 1000;
            return 0 if ++$count > 5000;
            if ($node->{kind} eq 'book') {
                return 0 unless defined $node->{comicID} && !ref($node->{comicID}) && length($node->{comicID}) <= 200;
            } else {
                return 0 unless ref($node->{children}) eq 'ARRAY';
                return 0 unless $walk->($node->{children}, $depth + 1);
            }
        }
        return 1;
    };
    return $walk->($nodes, 0);
}

sub list ($self) {
    my @presets = sort { ($b->{updatedAt} // '') cmp ($a->{updatedAt} // '') } _all($self);
    return $self->render(json => { success => 1, presets => [map {{id=>$_->{id}, name=>$_->{name}, updatedAt=>$_->{updatedAt}}} @presets] });
}

sub get ($self) {
    my $redis = LANraragi::Model::Config->get_redis;
    my $raw = $redis->hget($KEY, $self->stash('id'));
    $redis->quit;
    return $self->render(json => {success=>0,error=>'找不到这个书架预设。'}, status=>404) unless $raw;
    my $preset = eval { decode_json($raw) };
    return $self->render(json => {success=>1,preset=>$preset});
}

sub create ($self) {
    my $body = $self->req->json || {};
    my $name = $body->{name} // '';
    return $self->render(json=>{success=>0,error=>'预设名称需要 1 到 80 个字符。'},status=>400)
      if ref($name) || $name !~ /\S/ || length($name) > 80;
    return $self->render(json=>{success=>0,error=>'书架排列数据无效或超出限制。'},status=>400) unless _valid_nodes($body->{nodes});
    my @existing = _all($self);
    return $self->render(json=>{success=>0,error=>'最多保存 50 个预设。'},status=>409) if @existing >= 50;
    my $id = join('-', map { sprintf('%08x', int(rand(0xffffffff))) } 1..2);
    my $preset = { id=>$id, name=>$name, updatedAt=>_timestamp(), nodes=>$body->{nodes} };
    my $redis = LANraragi::Model::Config->get_redis;
    $redis->hset($KEY, $id, encode_json($preset));
    $redis->quit;
    return $self->render(json=>{success=>1,preset=>$preset},status=>201);
}

sub save ($self) {
    my $id = $self->stash('id');
    my $body = $self->req->json || {};
    return $self->render(json=>{success=>0,error=>'书架排列数据无效或超出限制。'},status=>400) unless _valid_nodes($body->{nodes});
    my $name = $body->{name};
    return $self->render(json=>{success=>0,error=>'预设名称需要 1 到 80 个字符。'},status=>400)
      if defined($name) && (ref($name) || $name !~ /\S/ || length($name) > 80);
    my $redis = LANraragi::Model::Config->get_redis;
    my $raw = $redis->hget($KEY, $id);
    unless ($raw) { $redis->quit; return $self->render(json=>{success=>0,error=>'找不到这个书架预设。'},status=>404); }
    my $preset = eval { decode_json($raw) };
    if (($body->{expectedUpdatedAt} // '') ne ($preset->{updatedAt} // '')) {
        $redis->quit;
        return $self->render(json=>{success=>0,error=>'这个预设已在其他设备更新，请先刷新再保存。',preset=>$preset},status=>409);
    }
    $preset->{nodes} = $body->{nodes};
    $preset->{name} = $name if defined $name;
    $preset->{updatedAt} = _timestamp();
    $redis->hset($KEY,$id,encode_json($preset));
    $redis->quit;
    return $self->render(json=>{success=>1,preset=>$preset});
}

1;
