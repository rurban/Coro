use Coro;
use Coro::Semaphore;
use Coro::Event;
use Coro::Socket;
use Coro::Signal;

use HTTP::Date;
use POSIX ();

no utf8;
use bytes;

# at least on my machine, this thingy serves files
# quite a bit faster than apache, ;)
# and quite a bit slower than thttpd :(

$SIG{PIPE} = 'IGNORE';

our $accesslog;
our $errorlog;

our $NOW;
our $HTTP_NOW;

Event->timer(interval => 1, hard => 1, cb => sub {
   $NOW = time;
   $HTTP_NOW = time2str $NOW;
})->now;

if ($ERROR_LOG) {
   use IO::Handle;
   open $errorlog, ">>$ERROR_LOG"
     or die "$ERROR_LOG: $!";
   $errorlog->autoflush(1);
}

if ($ACCESS_LOG) {
   use IO::Handle;
   open $accesslog, ">>$ACCESS_LOG"
     or die "$ACCESS_LOG: $!";
   $accesslog->autoflush(1);
}

sub slog {
   my $level = shift;
   my $format = shift;
   my $NOW = (POSIX::strftime "%Y-%m-%d %H:%M:%S", gmtime $::NOW);
   printf "$NOW: $format\n", @_;
   printf $errorlog "$NOW: $format\n", @_ if $errorlog;
}

our $connections = new Coro::Semaphore $MAX_CONNECTS || 250;
our $httpevent   = new Coro::Signal;

our $queue_file  = new transferqueue $MAX_TRANSFERS;
our $queue_index = new transferqueue 10;

my @newcons;
my @pool;

# one "execution thread"
sub handler {
   while () {
      if (@newcons) {
         eval {
            conn->new(@{pop @newcons})->handle;
         };
         slog 1, "$@" if $@ && !ref $@;

         $httpevent->broadcast; # only for testing, but doesn't matter much

         $connections->up;
      } else {
         last if @pool >= $MAX_POOL;
         push @pool, $Coro::current;
         schedule;
      }
   }
}

sub listen_on {
   my $listen = $_[0];

   push @listen_sockets, $listen;

   # the "main thread"
   async {
      slog 1, "accepting connections";
      while () {
         $connections->down;
         push @newcons, [$listen->accept];
         #slog 3, "accepted @$connections ".scalar(@pool);
         if (@pool) {
            (pop @pool)->ready;
         } else {
            async \&handler;
         }

      }
   };
}

my $http_port = new Coro::Socket
        LocalAddr => $SERVER_HOST,
        LocalPort => $SERVER_PORT,
        ReuseAddr => 1,
        Listen => 50,
   or die "unable to start server";

listen_on $http_port;

if ($SERVER_PORT2) {
   my $http_port = new Coro::Socket
           LocalAddr => $SERVER_HOST,
           LocalPort => $SERVER_PORT2,
           ReuseAddr => 1,
           Listen => 50,
      or die "unable to start server";

   listen_on $http_port;
}

package conn;

use Socket;
use HTTP::Date;
use Convert::Scalar 'weaken';
use Linux::AIO;

Linux::AIO::min_parallel $::AIO_PARALLEL;

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
   my $fh = shift;
   my $peername = shift;
   my $self = bless { fh => $fh }, $class;
   my (undef, $iaddr) = unpack_sockaddr_in $peername
      or $self->err(500, "unable to decode peername");

   $self->{remote_addr} =
      $self->{remote_id} = inet_ntoa $iaddr;
   $self->{time} = $::NOW;

   weaken ($Coro::current->{conn} = $self);

   $::conns++;
   $::maxconns = $::conns if $::conns > $::maxconns;

   $self;
}

sub DESTROY {
   #my $self = shift;
   $::conns--;
}

sub slog {
   my $self = shift;
   main::slog($_[0], "$self->{remote_id}> $_[1]");
}

sub response {
   my ($self, $code, $msg, $hdr, $content) = @_;
   my $res = "HTTP/1.1 $code $msg\015\012";

   if (exists $hdr->{Connection}) {
      if ($hdr->{Connection} =~ /close/) {
         $self->{h}{connection} = "close"
      }
   } else {
      if ($self->{version} < 1.1) {
         if ($self->{h}{connection} =~ /keep-alive/i) {
            $hdr->{Connection} = "Keep-Alive";
         } else {
            $self->{h}{connection} = "close"
         }
      }
   }

   $res .= "Date: $HTTP_NOW\015\012";

   while (my ($h, $v) = each %$hdr) {
      $res .= "$h: $v\015\012"
   }
   $res .= "\015\012";

   $res .= $content if defined $content and $self->{method} ne "HEAD";

   my $log = (POSIX::strftime "%Y-%m-%d %H:%M:%S", gmtime $NOW).
             " $self->{remote_id} \"$self->{uri}\" $code ".$hdr->{"Content-Length"}.
             " \"$self->{h}{referer}\"\n";

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

      # remote id should be unique per user
      my $id = $self->{remote_addr};

      if (exists $self->{h}{"client-ip"}) {
         $id .= "[".$self->{h}{"client-ip"}."]";
      } elsif (exists $self->{h}{"x-forwarded-for"}) {
         $id .= "[".$self->{h}{"x-forwarded-for"}."]";
      }

      $self->{remote_id} = $id;

      weaken (local $conn{$id}{$self*1} = $self);

      if ($blocked{$id}) {
         $self->err_blocked
            if $blocked{$id}[0] > $::NOW;

         delete $blocked{$id};
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
            = unpack_sockaddr_in $self->{fh}->sockname
               or $self->err(500, "unable to get socket name");
         $host = inet_ntoa $host;
      }

      $self->{server_name} = $host;

      weaken (local $uri{$id}{$self->{uri}}{$self*1} = $self);

      eval {
         $self->map_uri;
         $self->respond;
      };

      die if $@ && !ref $@;

      last if $self->{h}{connection} =~ /close/i;

      $httpevent->broadcast;

      $fh->timeout($::PER_TIMEOUT);
   }
}

sub block {
   my $self = shift;

   $blocked{$self->{remote_id}} = [$::NOW + $_[0], $_[1]];
   $self->slog(2, "blocked ip $self->{remote_id}");
   $self->err_blocked;
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

   if ($self->{name} =~ s%^/internal/([^/]+)%%) {
      if ($::internal{$1}) {
         $::internal{$1}->($self);
      } else {
         $self->err(404, "not found");
      }
   } else {

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
               # replace directory "size" by index.html filesize
               $self->{stat} = [stat ($self->{path} .= "/index.html")];
               $self->handle_file($queue_index);
            } else {
               $self->handle_dir;
            }
         }
      } elsif (-f _ && -r _) {
         -x _ and $self->err(403, "forbidden");

         if (%{$conn{$self->{remote_id}}} > $::MAX_TRANSFERS_IP) {
            my $timeout = $::NOW + 10;
            while (%{$conn{$self->{remote_id}}} > $::MAX_TRANSFERS_IP) {
               if ($timeout < $::NOW) {
                  $self->block($::BLOCKTIME, "too many connections");
               } else {
                  $httpevent->wait;
               }
            }
         }

         $self->handle_file($queue_file);
      } else {
         $self->err(404, "not found");
      }
   }
}

sub handle_dir {
   my $self = shift;
   my $idx = $self->diridx;

   $self->response(200, "ok",
         {
            "Content-Type"   => "text/html",
            "Content-Length" => length $idx,
            "Last-Modified"  => time2str ($self->{stat}[9]),
         },
         $idx);
}

sub handle_file {
   my ($self, $queue) = @_;
   my $length = $self->{stat}[7];
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
         my $timeout = $::NOW + 15;
         while (%{$uri{$self->{remote_id}}{$self->{uri}}} > 1) {
            if ($timeout <= $::NOW) {
               $self->block($::BLOCKTIME, "segmented downloads are forbidden");
               #$self->err_segmented_download;
            } else {
               $httpevent->wait;
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

      my $current = $Coro::current;

      my ($fh, $buf, $r);

      open $fh, "<", $self->{path}
         or die "$self->{path}: late open failure ($!)";

      $h -= $l - 1;

      if (0) { # !AIO
         if ($l) {
            sysseek $fh, $l, 0;
         }
      }
      
      my $transfer = $queue->start_transfer($h);
      my $locked;
      my $bufsize = $::WAIT_BUFSIZE; # initial buffer size

      while ($h > 0) {
         unless ($locked) {
            if ($locked ||= $transfer->try($::WAIT_INTERVAL)) {
               $bufsize = $::BUFSIZE;
               $self->{time} = $::NOW;
            }
         }

         if ($blocked{$self->{remote_id}}) {
            $self->{h}{connection} = "close";
            die bless {}, err:: 
         }

         if (0) { # !AIO
            sysread $fh, $buf, $h > $bufsize ? $bufsize : $h
               or last;
         } else {
            aio_read($fh, $l, ($h > $bufsize ? $bufsize : $h),
                     $buf, 0, sub {
                        $r = $_[0];
                        Coro::ready($current);
                     });
            &Coro::schedule;
            last unless $r;
         }
         my $w = syswrite $self->{fh}, $buf
            or last;
         $::written += $w;
         $self->{written} += $w;
         $l += $r;
      }

      close $fh;
   }
}

1;
