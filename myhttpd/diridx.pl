use List::Util qw(sum);

use Coro::AIO ();
use Storable ();

my $SD_VERSION = 1;

my $ignore = qr/ ^(?:robots.txt$|\.) /x;

our %diridx;

if ($db_env) {
   tie %diridx, BerkeleyDB::Hash,
       -Env => $db_env,
       -Filename => "directory",
       -Flags => DB_CREATE,
          or die "unable to create database index";
}

sub conn::gen_statdata {
   my $self = shift;
   my $data;
   
   {
      my $path = "";
      my $prefix = "";

      for ("http://".$self->server_hostport, split /\//, substr $self->{name}, 1) {
         next if $_ eq ".";
         $path .= "<a href='".escape_uri("$prefix$_")."/'>$_</a> / ";
         $prefix .= "$_/";
      }
      $data->{path} = $path;
   }

   {
      my $path = $self->{path};
      do {
         Coro::AIO::aio_load "$path.dols/top", $data->{top}
            unless Coro::AIO::aio_stat "$path.dols/top";
         Coro::AIO::aio_load "$path.dols/bot", $data->{bot}
            unless Coro::AIO::aio_stat "$path.dols/bot";
         $path =~ s/[^\/]*\/+$//
            or die "malformed path: $path";
      } while $path ne "";
   }

   my $entries = Coro::AIO::aio_readdir $self->{path};

   {
      my $dlen = 0;
      my $flen = 0;
      my $slen = 0;

      for (sort @$entries) {
         next if /$ignore/;

         Coro::AIO::aio_stat "$self->{path}$_";
         if (-d _) {
            next unless 0555 == ((stat _)[2] & 0555);
            $dlen = length $_ if length $_ > $dlen;
            push @{$data->{d}}, $_;
         } else {
            next unless 0444 == ((stat _)[2] & 0444);
            my $s = -s _;
            $flen = length $_ if length $_ > $dlen;
            $slen = length $s if length $s > $dlen;
            push @{$data->{f}}, [$_, $s];
         }
      }
      $data->{dlen} = $dlen;
      $data->{flen} = $flen;
      $data->{slen} = $slen;
   }

   $data
}

sub conn::get_statdata {
   my $self = shift;

   my $mtime = $self->{stat}[9];
   my $statdata;

#   $statdata = $diridx{$self->{path}};
#
#   if (defined $statdata) {
#      $$statdata = Storable::thaw $statdata;
#      return $$statdata
#         if $$statdata->{version} == $SD_VERSION
#            && $$statdata->{mtime} == $mtime;
#   }

#   $self->slog(8, "creating index cache for $self->{path}");

   $$statdata = $self->gen_statdata;
   $$statdata->{version} = $SD_VERSION;
   $$statdata->{mtime}   = $mtime;

#   $diridx{$self->{path}} = Storable::freeze $$statdata;
#   (tied %diridx)->db_sync;

   $$statdata
}

sub handle_redirect { # unused
   if (-f ".redirect") {
      if (open my $fh, "<.redirect") {
         while (<$fh>) {
            if (/^(?:$host$port)$uri([^ \tr\n]*)[ \t\r\n]+(.*)$/) {
               my $rem = $1;
               my $url = $2;
               print $nph ? "HTTP/1.0 302 Moved\n" : "Status: 302 Moved\n";
               print <<EOF;
Location: $url
Content-Type: text/html

<html>
<head><title>Page Redirection to $url</title></head>
<meta http-equiv="refresh" content="0;URL=$url">
</head>
<body text="black" link="#1010C0" vlink="#101080" alink="red" bgcolor="white">
<large>
This page has moved to $url.<br />
<a href="$url">
The automatic redirection has failed. Please try a <i>slightly</i>
newer browser next time, and in the meantime <i>please</i> follow this link ;)
</a>
</large>
</body>
</html>
EOF
            }
         }
      }
   }
}

sub format_time {
   if ($_[0] < 0) {
      "--:--:--";
   } elsif ($_[0] >= 60*60*24) {
      sprintf "%dd&#160;%02d:%02d:%02d",
              int ($_[0] / (60 * 60 * 24)),
              int ($_[0] / (60 * 60)) % 24,
              int ($_[0] / 60) % 60,
              int ($_[0]) % 60;
   } else {
      sprintf "%02d:%02d:%02d",
              int ($_[0] / (60 * 60)) % 24,
              int ($_[0] / 60) % 60,
              int ($_[0]) % 60;
   }
}

sub conn::diridx {
   my $self = shift;

   my $data = $self->get_statdata;

   my $stat;
   if ($data->{dlen}) {
      $stat .= "<table><tr><th>Directories</th></tr>";
      $data->{dlen} += 1;
      my $cols = int ((79 + $data->{dlen}) / $data->{dlen});
      $cols = @{$data->{d}} if @{$data->{d}} < $cols;
      my $col = $cols;
      for (@{$data->{d}}) {
         if (++$col >= $cols) {
            $stat .= "<tr>";
            $col = 0;
         }
         if ("$self->{path}$_" =~ $conn::blockuri{$self->{country}}) {
            $stat .= "<td>$_ ";
         } else {
            $stat .= "<td><a href='".escape_uri("$_/")."'>$_</a> ";
         }
      }
      $stat .= "</table>";
   }
   if ($data->{flen}) {
      $data->{flen} += 1 + $data->{slen} + 1 + 3;
      my $cols = int ((79 + $data->{flen}) / $data->{flen});
      $cols = @{$data->{f}} if @{$data->{f}} < $cols;
      my $col = $cols;
      $stat .= "<table><tr>". ("<th align='left'>File<th>Size<th>&nbsp;" x $cols);
      for (@{$data->{f}}) {
         if (++$col >= $cols) {
            $stat .= "<tr>";
            $col = 0;
         }
         $stat .= "<td><a href='".escape_uri($_->[0])."'>$_->[0]</a><td align='right'>$_->[1]<td>&nbsp;";
      }
      $stat .= "</table>";
   }

   <<EOF;
<html>
<head><title>$self->{uri}</title></head>
<body bgcolor="#ffffff" text="#000000" link="#0000ff" vlink="#000080" alink="#ff0000">
<h1>$data->{path}</h1>
$data->{top}
<hr />
<a href="/internal/status">Server Status Page &amp; Queueing Info</a>
<hr />
$stat
$data->{bot}
</body>
</html>
EOF
}

1;
