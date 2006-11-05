=head1 NAME

Coro::Socket - non-blocking socket-io

=head1 SYNOPSIS

 use Coro::Socket;

 # listen on an ipv4 socket
 my $socket = new Coro::Socket PeerHost => "localhost",
                               PeerPort => 'finger';

 # listen on any other type of socket
 my $socket = Coro::Socket->new_from_fh
                 (IO::Socket::UNIX->new
                     Local  => "/tmp/socket",
                     Type   => SOCK_STREAM,
                 );

=head1 DESCRIPTION

This module implements socket-handles in a coroutine-compatible way,
that is, other coroutines can run while reads or writes block on the
handle. L<Coro::Handle>.

=over 4

=cut

package Coro::Socket;

no warnings "uninitialized";

use strict;

use Errno ();
use Carp qw(croak);
use Socket;
use IO::Socket::INET ();

use Coro::Util ();

use base qw(Coro::Handle IO::Socket::INET);

our $VERSION = 1.9;

our (%_proto, %_port);

sub _proto($) {
   $_proto{$_[0]} ||= do {
      ((getprotobyname $_[0])[2] || (getprotobynumber $_[0])[2])
         or croak "unsupported protocol: $_[0]";
   };
}

sub _port($$) {
   $_port{$_[0],$_[1]} ||= do {
      return $_[0] if $_[0] =~ /^\d+$/;

      $_[0] =~ /([^(]+)\s*(?:\((\d+)\))?/x
         or croak "unparsable port number: $_[0]";
      ((getservbyname $1, $_[1])[2]
        || (getservbyport $1, $_[1])[2]
        || $2)
         or croak "unknown port: $_[0]";
   };
}

sub _sa($$$) {
   my ($host, $port, $proto) = @_;
   $port or $host =~ s/:([^:]+)$// and $port = $1;
   my $_proto = _proto($proto);
   my $_port = _port($port, $proto);

   # optimize this a bit for a common case
   if (Coro::Util::dotted_quad $host) {
      return pack_sockaddr_in ($_port, inet_aton $host);
   } else {
      my (undef, undef, undef, undef, @host) = Coro::Util::gethostbyname $host
         or croak "unknown host: $host";
      map pack_sockaddr_in ($_port,$_), @host;
   }
}

=item $fh = new Coro::Socket param => value, ...

Create a new non-blocking tcp handle and connect to the given host
and port. The parameter names and values are mostly the same as in
IO::Socket::INET (as ugly as I think they are).

If the host is unreachable or otherwise cannot be connected to this method
returns undef. On all other errors ot croak's.

Multihomed is always enabled.

   $fh = new Coro::Socket PeerHost => "localhost", PeerPort => 'finger';

=cut

sub _prepare_socket {
   my ($self, $arg) = @_;

   $self
}
   
sub new {
   my ($class, %arg) = @_;

   $arg{Proto}     ||= 'tcp';
   $arg{LocalHost} ||= delete $arg{LocalAddr};
   $arg{PeerHost}  ||= delete $arg{PeerAddr};
   defined ($arg{Type}) or $arg{Type} = $arg{Proto} eq "tcp" ? SOCK_STREAM : SOCK_DGRAM;

   socket my $fh, PF_INET, $arg{Type}, _proto ($arg{Proto})
      or return;

   my $self = bless Coro::Handle->new_from_fh (
      $fh,
      timeout       => $arg{Timeout},
      forward_class => $arg{forward_class},
      partial       => $arg{partial},
   ), $class
      or return;

   $self->configure (\%arg)
}

sub configure {
   my ($self, $arg) = @_;

   if ($arg->{ReuseAddr}) {
      $self->setsockopt (SOL_SOCKET, SO_REUSEADDR, 1)
         or croak "setsockopt(SO_REUSEADDR): $!";
   }

   if ($arg->{ReusePort}) {
      $self->setsockopt (SOL_SOCKET, SO_REUSEPORT, 1)
         or croak "setsockopt(SO_REUSEPORT): $!";
   }

   if ($arg->{LocalPort} || $arg->{LocalHost}) {
      my @sa = _sa($arg->{LocalHost} || "0.0.0.0", $arg->{LocalPort} || 0, $arg->{Proto});
      $self->bind ($sa[0])
         or croak "bind($arg->{LocalHost}:$arg->{LocalPort}): $!";
   }

   if ($arg->{PeerHost}) {
      my @sa = _sa ($arg->{PeerHost}, $arg->{PeerPort}, $arg->{Proto});

      for (@sa) {
         $! = 0;

         if ($self->connect ($_)) {
            next unless writable $self;
            $! = unpack "i", $self->getsockopt (SOL_SOCKET, SO_ERROR);
         }

         $! or last;

         $!{ECONNREFUSED} or $!{ENETUNREACH} or $!{ETIMEDOUT} or $!{EHOSTUNREACH}
            or return;
      }
   } elsif (exists $arg->{Listen}) {
      $self->listen ($arg->{Listen})
         or return;
   }

   1
}

=item connect, listen, bind, getsockopt, setsockopt,
send, recv, peername, sockname, shutdown, peerport, peerhost

Do the same thing as the perl builtins or IO::Socket methods (but return
true on EINPROGRESS). Remember that these must be method calls.

=cut

sub connect	{ connect tied(${$_[0]})->[0], $_[1] or $! == Errno::EINPROGRESS }
sub bind	{ bind    tied(${$_[0]})->[0], $_[1] }
sub listen	{ listen  tied(${$_[0]})->[0], $_[1] }
sub getsockopt	{ getsockopt tied(${$_[0]})->[0], $_[1], $_[2] }
sub setsockopt	{ setsockopt tied(${$_[0]})->[0], $_[1], $_[2], $_[3] }
sub send	{ send tied(${$_[0]})->[0], $_[1], $_[2], @_ > 2 ? $_[3] : () }
sub recv	{ recv tied(${$_[0]})->[0], $_[1], $_[2], @_ > 2 ? $_[3] : () }
sub sockname	{ getsockname tied(${$_[0]})->[0] }
sub peername	{ getpeername tied(${$_[0]})->[0] }
sub shutdown	{ shutdown tied(${$_[0]})->[0], $_[1] }

=item ($fh, $peername) = $listen_fh->accept

In scalar context, returns the newly accepted socket (or undef) and in
list context return the ($fh, $peername) pair (or nothing).

=cut

sub accept {
   my ($peername, $fh);
   while () {
      $peername = accept $fh, tied(${$_[0]})->[0]
         and return wantarray 
                    ? ($_[0]->new_from_fh($fh), $peername)
                    :  $_[0]->new_from_fh($fh);

      return unless $!{EAGAIN};

      $_[0]->readable or return;
   }
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

