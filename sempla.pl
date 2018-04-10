#/usr/bin/env perl
# HTML5 player with flac transcoding

use Mojolicious::Lite;

app->secrets(rand());
app->attr('music_root' => '/music/lossless/');
app->attr('ffmpeg' => '/usr/local/bin/ffmpeg');
#app->log->level('error');
app->static->paths->[0] = app->music_root;

app->helper(url_for_trailed => sub {
    my $url = shift->url_for(shift);
    $url .= '/' unless substr($url, -1) eq '/';
    return $url;
});

# Rewrite if behind proxy pass.
app->hook('before_dispatch' => sub {
    my $c = shift;
    app->attr('base' => '');
    if ($c->req->headers->header('X-Forwarded-For')) {
        my $base = shift @{$c->req->url->path->leading_slash(0)};
        push(@{$c->req->url->base->path->trailing_slash(1)}, $base);
        app->attr('base' => $base);
        $c->app->log->debug("Request under proxy pass, app->base = '".app->base()."'");
    }
});

get '/*file/transcode' => sub {
    my $c = shift->render_later;
    $c->inactivity_timeout(3600);
    my $file = $c->app->music_root.$c->stash('file');
    $c->app->log->debug("### TRANSCODE '$file'");
    my $content_length = 0;

#    my @cmd = (app->ffmpeg(), '-loglevel', 'warning', '-i', quotemeta($file), '-map', '0:a', '-codec:a', 'opus', '-b:a', '128k', '-vbr', 'on', '-f', 'opus', '-');
    my @cmd = (app->ffmpeg(), '-loglevel', 'warning', '-i', quotemeta($file), '-map', '0:a', '-codec:a', 'libvorbis', '-q:a', 4, '-f', 'ogg', '-');
    my $cmd = join(" ", @cmd);
    my $pid = open(my $ffmpeg_fh, "$cmd |") or die("Error executing ffmpeg: $!");
    $c->app->log->debug("ffmpeg($pid) CMD: '$cmd'");

    $c->res->headers->content_type('audio/ogg');
    my $stream = Mojo::IOLoop::Stream->new($ffmpeg_fh)->timeout(3600);
    $stream->on(read => sub {
        my ($stream, $bytes) = @_;
        $content_length += length($bytes);
        $c->write_chunk($bytes) if $c->tx;
    });

    Mojo::IOLoop->stream($c->tx->connection)->timeout(3600);
    my $sid = Mojo::IOLoop->stream($stream);

    $stream->on(close => sub {
        my $stream = shift;
        $c->app->log->debug("ffmpeg($pid) closed, $content_length bytes");
        kill(9, $pid) if $pid;
        close $ffmpeg_fh;
    });

    $c->on(finish => sub {
        my $c = shift;
        $c->app->log->debug("ffmpeg($pid) Connection finished");
        $stream->close_gracefully;
    });

    $stream->start;
};

get '/*path' => { path => ''} => sub {
    my $c = shift;
    my $path = '/'.$c->stash('path');
    $c->app->log->debug("### PATH '$path'");
    my @files;
    my @dirs;
    opendir(DIR, $c->app->music_root.$path) if -d $c->app->music_root.$path;
    my @items = map { Encode::decode('UTF-8', $_) } CORE::readdir(DIR);
    return $c->reply->not_found unless @items;

    my $img;
    my $size = 0;
    foreach my $item (@items) {
        next if ($item =~ '^[\.]+$' );
        if (-d $c->app->music_root.$path.$item) {
            push(@dirs, $item);
        } elsif (-f $c->app->music_root.$path.$item) {
            $img = 1 if $item eq 'folder.jpg';
            my @stat = stat($c->app->music_root.$path.$item);
            my $file;
            $file->{"name"} = $item;
            $file->{"size"} = sprintf("%.1f", ($stat[7])/(1024*1024));
            $size += $file->{"size"};
            push(@files, $file);
        }
    }

    $c->render("index", size => $size, path => $path, img => $img, files => \@files, dirs => \@dirs);
};

app->start;

__DATA__

@@ index.html.ep
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
    <title><%= $path %></title>
    %= stylesheet 'https://cdnjs.cloudflare.com/ajax/libs/semantic-ui/2.2.4/semantic.min.css'
    <style>
      .background {
        z-index: -1;
        position: fixed;
        % if ($img) {
          background-image: url('folder.jpg');
        % } else {
          background: linear-gradient(to bottom, rgba(125,126,125,1) 0%,rgba(14,14,14,1) 100%);
        % }
        background-size: cover;
        filter: blur(6px);
        -webkit-filter: blur(6px);
        height: 100%;
        width: 100%;
      }
      #trans { background-color: rgba(0,0,0,.7); }
    </style>
  </head>
  <body>
    <div class="background"></div>
    <div class="ui text container">
      <div id="trans" class="ui black message"><i class="music icon"></i><%= $path %></div>
      <audio id="player" preload="auto" preload autoplay></audio>
    </div>
    <div class="ui borderless inverted main menu">
      <div class="ui text container main ">
        <a class="item" id="loop"><i class="repeat icon"></i>Repeat Track</a>
        <a class="item" id="play"><i class="play icon"></i>Play</a>
        <a class="fitted item"><i><input id="seekbar" type="range"></i></input></a>
        <a class="item"><i class="wait icon"></i><i id="time">00:00:00 / 00:00:00 (0%)</i></a>
      </div>
    </div>
    <div class="ui text container">
      <div id="trans" class="ui segment">
        %= include 'description'
        %= include 'dirlist'
        %= include 'filelist'
      </div>
      <h2 class="ui header"></h2>
    </div>
    %= include 'javascript'
  </body>
</html>

@@ description.html.ep
<div class="ui equal width grid">
  <div class="row">
    % if ($img) {
      <div class="column">
        <div class="overlay">
          <div class="ui labeled icon vertical menu">
            <img id="albumart" class="ui medium centered rounded image" src="folder.jpg">
          </div>
        </div>
      </div>
    % }
    <div class="column">
      <div id="trans" class="ui inverted segment">
        <div class="ui inverted relaxed list">
          <div class="item">
            <i class="folder open outline icon"></i><div class="content"><%= $path %></div>
          </div>
          <div class="item">
            <i class="file outline icon"></i><div class="content"><%= scalar @{ $files } %> files</div>
          </div>
          <div class="item">
            <i class="disk outline icon"></i><div class="content"><%= $size %> MB</div>
          </div>
          <div class="item">
            <i class="file audio outline icon"></i><div id="temp" class="content">None</div>
          </div>
          <div class="item">
            <i class="cloud download icon"></i><div id="buf" class="content">Idle</div>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

@@ dirlist.html.ep
<table class="ui selectable inverted compact fixed table">
  <thead><tr><th>
    <button id="back" class="ui inverted basic white icon button"><i class="arrow left icon"></i>Back</button>
    <button id="home" class="ui inverted basic white icon button"><i class="home icon"></i>Home</button>
  </th></tr></thead>
  <tbody id="dir_list">
    % foreach my $dir (sort { lc($a) cmp lc($b) } @{ $dirs }) {
      <tr><td><i class="folder icon"></i><%= $dir %></td></tr>
    % }
  </tbody>
</table>

@@ filelist.html.ep
% if (scalar @{ $files }) {
<table class="ui selectable compact table">
  <thead><tr><th class="fourteen wide">Name</th><th class="two wide">Size</th></tr></thead>
  <tbody id="song_list">
    % foreach my $file (sort { lc($a->{name}) cmp lc($b->{name}) } @{ $files }) {
      <tr><td><i class="file outline icon"></i><%= $file->{name} %></td><td><%= $file->{size}.'MB' %></td></tr>
    % }
  </tbody>
</table>
% }

@@ javascript.html.ep
%= javascript 'https://ajax.googleapis.com/ajax/libs/jquery/1.12.4/jquery.min.js'
%= javascript 'https://cdnjs.cloudflare.com/ajax/libs/semantic-ui/2.2.4/semantic.min.js'
%= javascript begin
  var player      = document.getElementById('player');
  var seekbar     = document.getElementById('seekbar');
  var netStates   = {0:'Empty', 1:'Idle', 2:'Loading', 3:'No Source'};
  var oldBuffered = 0;
  seekbar.value   = 0;

  seekbar.onchange = function(){ player.currentTime = seekbar.value; }
  player.onplay    = function(){ $('#play').empty().append('<i class="pause icon"></i>Pause'); }
  player.onpause   = function(){ $('#play').empty().append('<i class="play icon"></i>Play'); }
  player.onended   = function(){ $('#loop i').hasClass('exchange')
                               ? player.play()
                               : $('tr.warning td:first-child').click();
                               }

  player.ontimeupdate = function(){
    if (player.buffered.length > 0){
      var lastBuffered = player.buffered.end(player.buffered.length-1);
      var timeBuffered = (lastBuffered - oldBuffered).toFixed(1);
      if (timeBuffered > 0){ $('#buf').text(netStates[player.networkState] + ' +' + timeBuffered + 's'); }
      oldBuffered   = lastBuffered
      seekbar.min   = player.startTime;
      seekbar.max   = lastBuffered;
      seekbar.value = player.currentTime;
    }
    var curtime = new Date(seekbar.value * 1000).toISOString().substr(11, 8);
    var tottime = new Date(seekbar.max * 1000).toISOString().substr(11, 8);
    var percent = Math.floor((seekbar.value / seekbar.max) * 100);
    $('#time').text(curtime + ' / ' + tottime + ' (' + percent + '%)');
  }

  $('#dir_list tr td').click(function(){
    window.location.replace("<%== url_for_trailed %>" + encodeURIComponent( $(this).text() ) + '/');
  });

  $('#song_list tr td').click(function() {
    $('#song_list tr').removeClass('active warning');
    $(this).parents('tr').addClass('active');
    $(this).parents('tr').next().addClass('warning');
    var file = $(this).text();
    var extension = file.split('.').pop();
    $('#temp').text(file);
    if ( !!(player.canPlayType('audio/' + extension).replace(/no/, '')) ) {
      player.src = file;
      player.play();
    } else if (extension === 'flac') {
      player.src = "<%== url_for_trailed %>" + encodeURIComponent(file) + '/transcode';
      player.play();
    } else {
      window.open(file, '_blank');
    }
  });

  $('#loop').click(function(){ $('#loop i').hasClass('exchange') ? $('#loop').empty().append('<i class="repeat icon"></i>Repeat Track') : $('#loop').empty().append('<i class="exchange icon"></i>Dont Repeat') })
  $('#play').click(function(){ player.paused == true ? player.play() : player.pause() })
  $('#home').click(function(){ window.location.replace("<%== app->base() %>"); })
  $('#back').click(function(){ window.location.replace("<%== url_for_trailed %>" + '../'); })
  $('#time').click(function(){ new Audio('data:audio/wav;base64,UklGRl9vT19XQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YU'+Array(1e3).join(123)).play(); })

  // fix main menu to page on passing
  $(document).ready(function() { $('.main.menu').visibility({ type: 'fixed' }); })
% end
