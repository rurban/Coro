use Coro;
use Coro::Semaphore;
use Coro::Event;
use Coro::Socket;

use HTTP::Date;

no utf8;
use bytes;

# at least on my machine, this thingy serves files
# quite a bit faster than apache, ;)
# and quite a bit slower than thttpd :(

$SIG{PIPE} = 'IGNORE';

our $accesslog;

if ($ACCESS_LOG) {
   use IO::Handle;
   open $accesslog, ">>$ACCESS_LOG"
     or die "$ACCESS_LOG: $!";
   $accesslog->autoflush(1);
}

sub slog {
   my $level = shift;
   my $format = shift;
   printf "---: $format\n", @_;
}

our $connections = new Coro::Semaphore $MAX_CONNECTS || 250;

our $wait_factor = 0.95;

our @transfers = (
  [(new Coro::Semaphore $MAX_TRANSFERS_SMALL || 50), 1],
  [(new Coro::Semaphore $MAX_TRANSFERS_LARGE || 50), 1],
);

my @newcons;
my @pool;

# one "execution thread"
sub handler {
   while () {
      my $new = pop @newcons;
      if ($new) {
         eval {
            conn->new(@$new)->handle;
         };
         slog 1, "$@" if $@ && !ref $@;
         $connections->up;
      } else {
         last if @pool >= $MAX_POOL;
         push @pool, $Coro::current;
         schedule;
      }
   }
}

my $http_port = new Coro::Socket
        LocalAddr => $SERVER_HOST,
        LocalPort => $SERVER_PORT,
        ReuseAddr => 1,
        Listen => 50,
   or die "unable to start server";

push @listen_sockets, $http_port;

our $NOW;
our $HTTP_NOW;

Event->timer(interval => 1, hard => 1, cb => sub {
   $NOW = time;
   $HTTP_NOW = time2str $NOW;
})->now;

# the "main thread"
async {
   slog 1, "accepting connections";
   while () {
      $connections->down;
      push @newcons, [$http_port->accept];
      #slog 3, "accepted @$connections ".scalar(@pool);
      if (@pool) {
         (pop @pool)->ready;
      } else {
         async \&handler;
      }

   }
};

package conn;

use Socket;
use HTTP::Date;
use Convert::Scalar 'weaken';
use Linux::AIO;

Linux::AIO::min_parallel $::AIO_PARALLEL;

my $aio_requests = new Coro::Semaphore $::AIO_PARALLEL * 4;

Event->io(fd => Linux::AIO::poll_fileno,
          poll => 'r', async => 1,
          cb => \&Linux::AIO::poll_cb);

our %conn; # $conn{ip}{self} => connobj
our %uri;  # $uri{ip}{uri}{self}
our %blocked;
our %mimetype;

sub read_mimetypes {
   local *M;
   if (open M, "<mime_types") {
      while (<M>) {
         if (/^([^#]\S+)\t+(\S+)$/) {
            $mimetype{lc $1} = $2;
         }
      }
   } else {
      print "cannot open mime_types\n";
   }
}

read_mimetypes;

sub new {
   my $class = shift;
   my $peername = shift;
   my $fh = shift;
   my $self = bless { fh => $fh }, $class;
   my (undef, $iaddr) = unpack_sockaddr_in $peername
      or $self->err(500, "unable to decode peername");

   $self->{remote_addr} = inet_ntoa $iaddr;
   $self->{time} = $::NOW;

   # enter ourselves into various lists
   weaken ($conn{$self->{remote_addr}}{$self*1} = $self);

   $::conns++;

   $self;
}

sub DESTROY {
   my $self = shift;

   $::conns--;

   $self->eoconn;
   delete $conn{$self->{remote_addr}}{$self*1};
}

# end of connection
sub eoconn {
   my $self = shift;
   delete $uri{$self->{remote_addr}}{$self->{uri}}{$self*1};
}

sub slog {
   my $self = shift;
   main::slog($_[0], ($self->{remote_id} || $self->{remote_addr}) ."> $_[1]");
}

sub response {
   my ($self, $code, $msg, $hdr, $content) = @_;
   my $res = "HTTP/1.1 $code $msg\015\012";

   $self->{h}{connection} ||= $hdr->{Connection};

   $res .= "Date: $HTTP_NOW\015\012";

   while (my ($h, $v) = each %$hdr) {
      $res .= "$h: $v\015\012"
   }
   $res .= "\015\012";

   $res .= $content if defined $content and $self->{method} ne "HEAD";

   my $log = "$self->{remote_addr} \"$self->{uri}\" $code ".$hdr->{"Content-Length"}." \"$self->{h}{referer}\"\n";

   print $accesslog $log if $accesslog;
   print STDERR $log;

   $self->{written} +=
      print {$self->{fh}} $res;
}

sub err {
   my $self = shift;
   my ($code, $msg, $hdr, $content) = @_;

   unless (defined $content) {
      $content = "$code $msg\n";
      $hdr->{"Content-Type"} = "text/plain";
      $hdr->{"Content-Length"} = length $content;
   }
   $hdr->{"Connection"} = "close";

   $self->response($code, $msg, $hdr, $content);

   die bless {}, err::;
}

sub handle {
   my $self = shift;
   my $fh = $self->{fh};

   my $host;

   $fh->timeout($::REQ_TIMEOUT);
   while() {
      $self->{reqs}++;

      # read request and parse first line
      my $req = $fh->readline("\015\012\015\012");

      unless (defined $req) {
         if (exists $self->{version}) {
            last;
         } else {
            $self->err(408, "request timeout");
         }
      }

      $self->{h} = {};

      $fh->timeout($::RES_TIMEOUT);
      my $ip = $self->{remote_addr};

      if ($blocked{$ip}) {
         $self->err_blocked($blocked{$ip})
            if $blocked{$ip} > $::NOW;

         delete $blocked{$ip};
      }

      if (%{$conn{$ip}} > $::MAX_CONN_IP) {
         my $delay = 120;
         while (%{$conn{$ip}} > $::MAX_CONN_IP) {
            if ($delay <= 0) {
               $self->slog(2, "blocked ip $ip");
               $self->err_blocked;
            } else {
               Coro::Event::do_timer(after => 3);
               $delay -= 3;
            }
         }
      }

      $req =~ /^(?:\015\012)?
                (GET|HEAD) \040+
                ([^\040]+) \040+
                HTTP\/([0-9]+\.[0-9]+)
                \015\012/gx
         or $self->err(405, "method not allowed", { Allow => "GET,HEAD" });

      $self->{method} = $1;
      $self->{uri} = $2;
      $self->{version} = $3;

      $3 =~ /^1\./
         or $self->err(506, "http protocol version $3 not supported");

      # parse headers
      {
         my (%hdr, $h, $v);

         $hdr{lc $1} .= ",$2"
            while $req =~ /\G
                  ([^:\000-\040]+):
                  [\008\040]*
                  ((?: [^\015\012]+ | \015\012[\008\040] )*)
                  \015\012
               /gxc;

         $req =~ /\G\015\012$/
            or $self->err(400, "bad request");

         $self->{h}{$h} = substr $v, 1
            while ($h, $v) = each %hdr;
      }

      # find out server name and port
      if ($self->{uri} =~ s/^http:\/\/([^\/?#]*)//i) {
         $host = $1;
      } else {
         $host = $self->{h}{host};
      }

      if (defined $host) {
         $self->{server_port} = $host =~ s/:([0-9]+)$// ? $1 : 80;
      } else {
         ($self->{server_port}, $host)
            = unpack_sockaddr_in $self->{fh}->getsockname
               or $self->err(500, "unable to get socket name");
         $host = inet_ntoa $host;
      }

      $self->{server_name} = $host;

      # remote id should be unique per user
      $self->{remote_id} = $self->{remote_addr};

      if (exists $self->{h}{"client-ip"}) {
         $self->{remote_id} .= "[".$self->{h}{"client-ip"}."]";
      } elsif (exists $self->{h}{"x-forwarded-for"}) {
         $self->{remote_id} .= "[".$self->{h}{"x-forwarded-for"}."]";
      }

      weaken ($uri{$self->{remote_addr}}{$self->{uri}}{$self*1} = $self);

      eval {
         $self->map_uri;
         $self->respond;
      };

      $self->eoconn;

      die if $@ && !ref $@;

      last if $self->{h}{connection} =~ /close/ || $self->{version} < 1.1;

      $fh->timeout($::PER_TIMEOUT);
   }
}

# uri => path mapping
sub map_uri {
   my $self = shift;
   my $host = $self->{server_name};
   my $uri = $self->{uri};

   # some massaging, also makes it more secure
   $uri =~ s/%([0-9a-fA-F][0-9a-fA-F])/chr hex $1/ge;
   $uri =~ s%//+%/%g;
   $uri =~ s%/\.(?=/|$)%%g;
   1 while $uri =~ s%/[^/]+/\.\.(?=/|$)%%;

   $uri =~ m%^/?\.\.(?=/|$)%
      and $self->err(400, "bad request");

   $self->{name} = $uri;

   # now do the path mapping
   $self->{path} = "$::DOCROOT/$host$uri";

   $self->access_check;
}

sub _cgi {
   my $self = shift;
   my $path = shift;
   my $fh;

   # no two-way xxx supported
   if (0 == fork) {
      open STDOUT, ">&".fileno($self->{fh});
      if (chdir $::DOCROOT) {
         $ENV{SERVER_SOFTWARE} = "thttpd-myhttpd"; # we are thttpd-alike
         $ENV{HTTP_HOST}       = $self->{server_name};
         $ENV{HTTP_PORT}       = $self->{server_port};
         $ENV{SCRIPT_NAME}     = $self->{name};
         exec $path;
      }
      Coro::State::_exit(0);
   } else {
      die;
   }
}

sub server_hostport {
   $_[0]{server_port} == 80
      ? $_[0]{server_name}
      : "$_[0]{server_name}:$_[0]{server_port}";
}

sub respond {
   my $self = shift;
   my $path = $self->{path};

   stat $path
      or $self->err(404, "not found");

   $self->{stat} = [stat _];

   # idiotic netscape sends idiotic headers AGAIN
   my $ims = $self->{h}{"if-modified-since"} =~ /^([^;]+)/
             ? str2time $1 : 0;

   if (-d _ && -r _) {
      # directory
      if ($path !~ /\/$/) {
         # create a redirect to get the trailing "/"
         # we don't try to avoid the :80
         $self->err(301, "moved permanently", { Location =>  "http://".$self->server_hostport."$self->{uri}/" });
      } else {
         $ims < $self->{stat}[9]
            or $self->err(304, "not modified");

         if (-r "$path/index.html") {
            $self->{path} .= "/index.html";
            $self->handle_file;
         } else {
            $self->handle_dir;
         }
      }
   } elsif (-f _ && -r _) {
      -x _ and $self->err(403, "forbidden");
      $self->handle_file;
   } else {
      $self->err(404, "not found");
   }
}

sub handle_dir {
   my $self = shift;
   my $idx = $self->diridx;

   $self->response(200, "ok",
         {
            "Content-Type"   => "text/html",
            "Content-Length" => length $idx,
         },
         $idx);
}

sub handle_file {
   my $self = shift;
   my $length = $self->{stat}[7];
   my $queue = $::transfers[$length >= $::TRANSFER_SMALL];
   my $hdr = {
      "Last-Modified"  => time2str ((stat _)[9]),
   };

   my @code = (200, "ok");
   my ($l, $h);

   if ($self->{h}{range} =~ /^bytes=(.*)$/) {
      for (split /,/, $1) {
         if (/^-(\d+)$/) {
            ($l, $h) = ($length - $1, $length - 1);
         } elsif (/^(\d+)-(\d*)$/) {
            ($l, $h) = ($1, ($2 ne "" || $2 >= $length) ? $2 : $length - 1);
         } else {
            ($l, $h) = (0, $length - 1);
            goto ignore;
         }
         goto satisfiable if $l >= 0 && $l < $length && $h >= 0 && $h >= $l;
      }
      $hdr->{"Content-Range"} = "bytes */$length";
      $hdr->{"Content-Length"} = $length;
      $self->err(416, "not satisfiable", $hdr, "");

satisfiable:
      # check for segmented downloads
      if ($l && $::NO_SEGMENTED) {
         my $delay = 180;
         while (%{$uri{$self->{remote_addr}}{$self->{uri}}} > 1) {
            if ($delay <= 0) {
               $self->err_segmented_download;
            } else {
               Coro::Event::do_timer(after => 3); $delay -= 3;
            }
         }
      }

      $hdr->{"Content-Range"} = "bytes $l-$h/$length";
      @code = (206, "partial content");
      $length = $h - $l + 1;

ignore:
   } else {
      ($l, $h) = (0, $length - 1);
   }

   $self->{path} =~ /\.([^.]+)$/;
   $hdr->{"Content-Type"} = $mimetype{lc $1} || "application/octet-stream";
   $hdr->{"Content-Length"} = $length;

   $self->response(@code, $hdr, "");

   if ($self->{method} eq "GET") {
      $self->{time} = $::NOW;

      my $fudge = $queue->[0]->waiters;
      $fudge = $fudge ? ($fudge+1)/$fudge : 1;

      $queue->[1] *= $fudge;
      my $transfer = $queue->[0]->guard;

      if ($fudge != 1) {
         $queue->[1] /= $fudge;
         $queue->[1] = $queue->[1] * $::wait_factor
                     + ($::NOW - $self->{time}) * (1 - $::wait_factor);
      }
      $self->{time} = $::NOW;

      $self->{fh}->writable or return;

      my ($fh, $buf, $r);
      my $current = $Coro::current;
      open $fh, "<", $self->{path}
         or die "$self->{path}: late open failure ($!)";

      $h -= $l - 1;

      if (0) {
         if ($l) {
            sysseek $fh, $l, 0;
         }
      }

      while ($h > 0) {
         if (0) {
            sysread $fh, $buf, $h > $::BUFSIZE ? $::BUFSIZE : $h
               or last;
         } else {
            undef $buf;
            $aio_requests->down;
            aio_read($fh, $l, ($h > $::BUFSIZE ? $::BUFSIZE : $h),
                     $buf, 0, sub {
                        $r = $_[0];
                        $current->ready;
                     });
            &Coro::schedule;
            $aio_requests->up;
            last unless $r;
         }
         my $w = $self->{fh}->syswrite($buf)
            or last;
         $::written += $w;
         $self->{written} += $w;
         $l += $r;
      }

      close $fh;
   }
}

1;
