use Coro;
use Coro::Semaphore;
use Coro::Event;
use Coro::Socket;

no utf8;
use bytes;

# at least on my machine, this thingy serves files
# quite a bit faster than apache, ;)
# and quite a bit slower than thttpd :(

my $port = new Coro::Socket
        LocalAddr => $SERVER_HOST,
        LocalPort => $SERVER_PORT,
        ReuseAddr => 1,
        Listen => 1,
   or die "unable to start server";

$SIG{PIPE} = 'IGNORE';
   
sub slog {
   my $level = shift;
   my $format = shift;
   printf "---: $format\n", @_;
}

my $connections = new Coro::Semaphore $MAX_CONNECTS;

my @fh;
my @pool;

# one "execution thread"
sub handler {
   while () {
      my $fh = pop @fh;
      if ($fh) {
         eval {
            conn->new($fh)->handle;
         };
         close $fh;
         slog 1, "$@" if $@ && !ref $@;
         $connections->up;
      } else {
         last if @pool >= $MAX_POOL;
         push @pool, $Coro::current;
         schedule;
      }
   }
}

# the "main thread"
async {
   slog 1, "accepting connections";
   while () {
      $connections->down;
      push @fh, $port->accept;
      #slog 3, "accepted @$connections ".scalar(@pool);
      $::NOW = time;
      if (@pool) {
         (pop @pool)->ready;
      } else {
         async \&handler;
      }

   }
};

loop;
print "ende\n";#d#

package conn;

use Socket;
use HTTP::Date;
use Convert::Scalar 'weaken';

our %conn; # $conn{ip}{fh} => connobj
our %blocked;

sub new {
   my $class = shift;
   my $fh = shift;
   my $self = bless { fh => $fh }, $class;
   my (undef, $iaddr) = unpack_sockaddr_in $fh->getpeername
      or $self->err(500, "unable to get peername");
   $self->{remote_addr} = inet_ntoa $iaddr;

   # enter ourselves into various lists
   weaken ($conn{$self->{remote_addr}}{$self*1} = $self);

   print "$self->{remote_addr}: ".($self*1)." > ".%{$conn{$self->{remote_addr}}},"\n";
   $self;
}

sub DESTROY {
   my $self = shift;
   delete $conn{$self->{remote_addr}}{$self*1};
   delete $uri{$self->{uri}}{$self*1};
}

sub slog {
   main::slog(@_);
}

sub print_response {
   my ($self, $code, $msg, $hdr, $content) = @_;
   my $res = "HTTP/1.0 $code $msg\015\012";

   $hdr->{Date} = time2str $::NOW; # slow? nah.

   while (my ($h, $v) = each %$hdr) {
      $res .= "$h: $v\015\012"
   }
   $res .= "\015\012$content" if defined $content;

   print STDERR "$self->{remote_addr} \"$self->{uri}\" $code ".$hdr->{"Content-Length"}." \"$self->{h}{referer}\"\n";#d#

   print {$self->{fh}} $res;
}

sub err {
   my $self = shift;
   my ($code, $msg, $hdr, $content) = @_;

   unless (defined $content) {
      $content = "$code $msg";
      $hdr->{"Content-Type"} = "text/plain";
      $hdr->{"Content-Length"} = length $content;
   }

   $self->slog($msg) if $code;

   $self->print_response($code, $msg, $hdr, $content);

   die bless {}, err::;
}

sub err_blocked {
   my $self = shift;
   my $ip = $self->{remote_addr};
   my $time = time2str $blocked{$ip} = $::NOW + $::BLOCKTIME;
   $self->err(403, "too many connections",
              { "Retry-After" => $::BLOCKTIME },
              <<EOF);
You have been blocked because you opened too many connections. You
may retry at $time. Until then,
every new access will renew the block.
EOF
}

sub handle {
   my $self = shift;
   my $fh = $self->{fh};

   #while() {
      $self->{h} = {};

      # read request and parse first line
      $fh->timeout($::REQ_TIMEOUT);
      my $req = $fh->readline("\015\012\015\012");
      $fh->timeout($::RES_TIMEOUT);

      defined $req or
         $self->err(408, "request timeout");

      my $ip = $self->{remote_addr};

      if ($blocked{$ip}) {
         $self->err_blocked($blocked{$ip})
            if $blocked{$ip} > $::NOW;

         delete $blocked{$ip};
      }

      if (%{$conn{$ip}} > $::MAX_CONN_IP) {
         $self->slog("blocked ip $ip");
         $self->err_blocked;
      }

      $req =~ /^(?:\015\012)?
                (GET|HEAD) \040+
                ([^\040]+) \040+
                HTTP\/([0-9]+\.[0-9]+)
                \015\012/gx
         or $self->err(403, "method not allowed", { Allow => "GET,HEAD" });

      $2 ne "1.0"
         or $self->err(506, "http protocol version not supported");

      $self->{method} = $1;
      $self->{uri} = $2;

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

      $self->{server_port} = $self->{h}{host} =~ s/:([0-9]+)$// ? $1 : 80;

      weaken ($uri{$self->{uri}}{$self*1} = $self);

      $self->map_uri;

      Coro::Event::do_timer(after => 5);
      
      $self->respond;
   #}
}

# uri => path mapping
sub map_uri {
   my $self = shift;
   my $host = $self->{h}{host} || "default";
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
}

sub server_address {
   my $self = shift;
   my ($port, $iaddr) = unpack_sockaddr_in $self->{fh}->getsockname
      or $self->err(500, "unable to get socket name");
   ((inet_ntoa $iaddr), $port);
}

sub server_host {
   my $self = shift;
   if (exists $self->{h}{host}) {
      return $self->{h}{host};
   } else {
      return (($self->server_address)[0]);
   }
}

sub server_hostport {
   my $self = shift;
   my ($host, $port);
   if (exists $self->{h}{host}) {
      ($host, $port) = ($self->{h}{host}, $self->{server_port});
   } else {
      ($host, $port) = $self->server_address;
   }
   $port = $port == 80 ? "" : ":$port";
   $host.$port;
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
         $ENV{HTTP_HOST}       = $self->server_host;
         $ENV{HTTP_PORT}       = $self->{server_host};
         $ENV{SCRIPT_NAME}     = $self->{name};
         exec $::INDEXPROG;
      }
      Coro::State::_exit(0);
   } else {
   }
}

sub respond {
   my $self = shift;
   my $path = $self->{path};

   stat $path
      or $self->err(404, "not found");

   # idiotic netscape sends idiotic headers AGAIN
   my $ims = $self->{h}{"if-modified-since"} =~ /^([^;]+)/
             ? str2time $1 : 0;

   if (-d _ && -r _) {
      # directory
      if ($path !~ /\/$/) {
         # create a redirect to get the trailing "/"
         my $host = $self->server_hostport;
         $self->err(301, "moved permanently", { Location =>  "http://$host$self->{uri}/" });
      } else {
         $ims < (stat _)[9]
            or $self->err(304, "not modified");

         if ($self->{method} eq "GET") {
            if (-r "$path/index.html") {
               $self->{path} .= "/index.html";
               $self->handle_file;
            } else {
               $self->handle_dir;
            }
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
   $self->_cgi($::INDEXPROG);
}

sub handle_file {
   my $self = shift;
   my $length = -s _;
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
         goto satisfiable if $l >= 0 && $l < $length && $h >= 0 && $h > $l;
      }
      $hdr->{"Content-Range"} = "bytes */$length";
      $self->err(416, "not satisfiable", $hdr);

satisfiable:
      $hdr->{"Content-Range"} = "bytes $l-$h/$length";
      @code = (206, "partial content");
      $length = $h - $l + 1;

ignore:
   } else {
      ($l, $h) = (0, $length - 1);
   }

   if ($self->{path} =~ /\.html$/) {
      $hdr->{"Content-Type"} = "text/html";
   } else {
      $hdr->{"Content-Type"} = "application/octet-stream";
   }

   $hdr->{"Content-Length"} = $length;

   $self->print_response(@code, $hdr, "");

   if ($self->{method} eq "GET") {
      my ($fh, $buf);
      open $fh, "<", $self->{path}
         or die "$self->{path}: late open failure ($!)";

      if ($l) {
         sysseek $fh, $l, 0
            or die "$self->{path}: cannot seek to $l ($!)";
      }

      $h -= $l - 1;

      while ($h > 0) {
         $h -= sysread $fh, $buf, $h > 4096 ? 4096 : $h;
         print {$self->{fh}} $buf
            or last;
      }
   }

   close $fh;
}

1;
