=head1 NAME

Coro::Socket - non-blocking socket-io

=head1 SYNOPSIS

 use Coro::Socket;

=head1 DESCRIPTION

This module implements socket-handles in a coroutine-compatible way,
that is, other coroutines can run while reads or writes block on the
handle. L<Coro::Handle>.

=over 4

=cut

package Coro::Socket;

use Errno ();
use Carp qw(croak);
use Socket;

use base 'Coro::Handle';

$VERSION = 0.12;

sub _proto($) {
   $_proto{$_[0]} ||= do {
      ((getprotobyname $_[0])[2] || (getprotobynumber $_[0])[2])
         or croak "unsupported protocol: $_[0]";
   };
}

sub _port($$) {
   $_port{$_[0]} ||= do {
      ((getservbyname $_[0], $_[1])[2] || (getservbyport $_[0], $_[1])[2])
         or croak "unknown port: $_[0]";
   };
}

sub _sa($$$) {
   my ($host, $port, $proto) = @_;
   my $_proto = _proto($proto);
   my $_port = _port($port, $proto);

   my (undef, undef, undef, undef, @host) = gethostbyname $host
      or croak "unknown host: $host";

   map pack_sockaddr_in($_port,$_), @host;
}

=item $fh = new_inet Coro::Socket param => value, ...

Create a new non-blocking tcp handle and connect to the given host
and port. The parameter names and values are mostly the same as in
IO::Socket::INET (as ugly as I think they are).

If the host is unreachable or otherwise cannot be connected to this method
returns undef. On all other errors ot croak's.

Multihomed is always enabled.

   $fh = new_inet Coro::Socket PeerHost => "localhost", PeerPort => 'finger';

=cut

sub _prepare_socket {
   my ($class, $arg) = @_;
   my $fh;

   socket $fh, PF_INET, $arg->{Type}, _proto($arg->{Proto})
      or return;

   $fh = bless Coro::Handle->new_from_fh($fh), $class
      or return;

   if ($arg->{ReuseAddr}) {
      $fh->setsockopt(SOL_SOCKET, SO_REUSEADDR, 1)
         or croak "setsockopt(SO_REUSEADDR): $!";
   }

   if ($arg->{ReusePort}) {
      $fh->setsockopt(SOL_SOCKET, SO_REUSEPORT, 1)
         or croak "setsockopt(SO_REUSEPORT): $!";
   }

   if ($arg->{LocalHost}) {
      my @sa = _sa($arg->{LocalHost}, $arg->{LocalPort}, $arg->{Proto});
      $fh->bind($sa[0])
         or croak "bind($arg->{LocalHost}:$arg->{LocalPort}): $!";
   }

   $fh;
}
   
sub new_inet {
   my $class = shift;
   my %arg = @_;
   my $fh;

   $arg{Proto}     ||= 'tcp';
   $arg{LocalHost} ||= delete $arg{LocalAddr};
   $arg{PeerHost}  ||= delete $arg{PeerAddr};
   defined ($arg{Type}) or $arg{Type} = $arg{Proto} eq "tcp" ? SOCK_STREAM : SOCK_DGRAM;

   if ($arg{PeerHost}) {
      my @sa = _sa($arg{PeerHost}, $arg{PeerPort}, $arg{Proto});

      for (@sa) {
         $fh = $class->_prepare_socket(\%arg)
            or return;

         $! = 0;

         if ($fh->connect($_)) {
            next unless writable $fh;
            $! = unpack "i", $fh->getsockopt(SOL_SOCKET, SO_ERROR);
         }

         $! or last;

         $!{ECONNREFUSED} or $!{ENETUNREACH} or $!{ETIMEDOUT} or $!{EHOSTUNREACH}
            or return;
      }
   } else {
      $fh = $class->_prepare_socket(\%arg)
         or return;

   }

   $fh;
}

=item connect, listen, bind, accept, getsockopt, setsockopt,
send , recv, getpeername, getsockname

Do the same thing as the perl builtins (but return true on
EINPROGRESS). Remember that these must be method calls.

=cut

sub connect	{ connect tied(${$_[0]})->{fh}, $_[1] or $! == Errno::EINPROGRESS }
sub bind	{ bind    tied(${$_[0]})->{fh}, $_[1] }
sub listen	{ listen  tied(${$_[0]})->{fh}, $_[1] }
sub getsockopt	{ getsockopt tied(${$_[0]})->{fh}, $_[1], $_[2] }
sub setsockopt	{ setsockopt tied(${$_[0]})->{fh}, $_[1], $_[2], $_[3] }
sub send	{ send tied(${$_[0]})->{fh}, $_[1], $_[2], @_ > 2 ? $_[3] : () }
sub recv	{ recv tied(${$_[0]})->{fh}, $_[1], $_[2], @_ > 2 ? $_[3] : () }
sub setsockname	{ getsockname tied(${$_[0]})->{fh} }
sub setpeername	{ getpeername tied(${$_[0]})->{fh} }

sub accept {
   my $fh;
   accept $fh, tied(${$_[0]})->{fh} and new_from_fh Coro::Handle $fh;
}

1;

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut
