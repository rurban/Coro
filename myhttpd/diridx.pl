use PApp::SQL;
use Storable ();

my $SD_VERSION = 1;

my $ignore = qr/ ^(?:robots.txt$|\.) /x;

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

   sub read_file {
      local ($/, *X);
      (open X, "<$_[0]\x00") ? <X> : ();
   }

   {
      my $path = $self->{path};
      do {
         $data->{top} ||= read_file "$path.dols/top";
         $data->{bot} ||= read_file "$path.dols/bot";
         $path =~ s/[^\/]*\/+$//
            or die "malformed path: $path";
      } while $path ne "";
   }

   local *DIR;
   if (opendir DIR, $self->{path}) {
      my $stat;

      my (@files, @dirs);
      my $dlen = 0;
      my $flen = 0;
      my $slen = 0;
      for (sort readdir DIR) {
         next if /$ignore/;
         stat "$self->{path}$_";
         next unless -r _;
         if (-d _) {
            $dlen = length $_ if length $_ > $dlen;
            push @dirs, "$_/";
         } else {
            my $s = -s _;
            $flen = length $_ if length $_ > $dlen;
            $slen = length $s if length $s > $dlen;
            push @files, [$_, $s];
         }
      }
      if (@dirs) {
         $stat .= "<table><tr><th>Directories</th></tr>";
         $dlen += 1;
         my $cols = int ((79 + $dlen) / $dlen);
         my $col = $cols;
         $cols = @dirs if @dirs < $cols;
         for (@dirs) {
            if (++$col >= $cols) {
               $stat .= "<tr>";
               $col = 0;
            }
            $stat .= "<td><a href='".escape_uri($_)."'>$_</a> ";
         }
         $stat .= "</table>";
      }
      if (@files) {
         $flen = $flen + 1 + $slen + 1 + 3;
         my $cols = int ((79 + $flen) / $flen);
         my $col = $cols;
         $cols = @files if @files < $cols;
         $stat .= "<table><tr>". ("<th align='left'>File<th>Size<th>&nbsp;" x $cols);
         for (@files) {
            if (++$col >= $cols) {
               $stat .= "<tr>";
               $col = 0;
            }
            $stat .= "<td><a href='".escape_uri($_->[0])."'>$_->[0]</a><td align='right'>$_->[1]<td>&nbsp;";
         }
         $stat .= "</table>";
      }
      $data->{stat} = $stat;
   } else {
      $data->{stat} = "Unable to index $uri: $!<br>";
   }

   $data;
}

use Tie::Cache;
tie %statdata_cache, Tie::Cache::, 70;

sub conn::get_statdata {
   my $self = shift;

   my $mtime = $self->{stat}[9];

   my $statdata = \$statdata_cache{$self->{path}, $mtime};

   return $$statdata if $$statdata;

   my $st = sql_exec $statdata,
                     "select statdata from diridx where mtime = ? and path = ?",
                     $mtime, $self->{path};

   if ($st->fetch) {
      $$statdata = Storable::thaw $$statdata;
      return $$statdata if $$statdata->{version} == $SD_VERSION;
   }

   $self->slog(8, "creating index cache for $self->{path}");

   $$statdata = $self->gen_statdata;
   $$statdata->{version} = $SD_VERSION;

   sql_exec "delete from diridx where path = ?", $self->{path};
   sql_exec "insert into diridx (path, mtime, statdata) values (?, ?, ?)",
            $self->{path}, $mtime, Storable::freeze $$statdata;

   $$statdata;
}

sub conn::diridx {
   my $self = shift;

   my $data = $self->get_statdata;

   my $uptime = int (time - $::starttime);
   $uptime = sprintf "%02dd %02d:%02d",
                     int ($uptime / (60 * 60 * 24)),
                     int ($uptime / (60 * 60)) % 24,
                     int ($uptime / 60) % 60;
   
   <<EOF;
<html>
<head><title>$self->{uri}</title></head>
<body bgcolor="#ffffff" text="#000000" link="#0000ff" vlink="#000080" alink="#ff0000">
<h1>$data->{path}</h1>
$data->{top}
<small><div align="right"><tt>$self->{remote_addr}/$self->{country} - $::conns connection(s) - uptime $uptime - myhttpd/$VERSION</tt></div></small>
<hr>
$data->{stat}
$data->{bot}
</body>
</html>
EOF
}

sub handle_redirect { # unused
   if (-f ".redirect") {
      if (open R, "<.redirect") {
         while (<R>) {
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

1;
