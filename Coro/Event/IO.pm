=head1 NAME

Coro::Event::IO - non-blocking io with a blocking interface.

=head1 SYNOPSIS

 use Coro::Event::IO;

=head1 DESCRIPTION

This module implements io-handles in a coroutine-compatible way, that is,
other coroutines can run while reads or writes block on the handle. It
does NOT inherit from IO::Handle but uses tied objects.

=over 4

=cut

package Coro::Event::IO;

use Errno ();

$VERSION = 0.10;

sub new_from_fh {
   my $class = shift;
   my $fh = shift;
   my $self = do { local *Coro::Event::IO };

   tie $self, Coro::Event::IO::FH, $fh;

   my $_fh = select bless \$self, $class;
   $| = 1;
   select $_fh;
}

sub connect {
   connect tied(${$_[0]})->{fh}, $_[1]
      or $! == Errno::EINPROGRESS;
}

package Coro::Event::IO::FH;

use Fcntl ();
use Errno ();

use Coro::Event;

use base 'Tie::Handle';

sub TIEHANDLE {
   my ($class, $fh) = @_;

   fcntl $fh, &Fcntl::F_SETFL, &Fcntl::O_NONBLOCK
      or die "fcntl(O_NONBLOCK): $!";

   bless {
      fh => $fh,
      rb => "",
      wb => "",
   }, $_[0];

}

sub OPEN {
   my $self = shift;
   $self->CLOSE;
   my $r = @_ == 2 ? open $self->{fh}, $_[0], $_[1]
                   : open $self->{fh}, $_[0], $_[1], $_[2];
   if ($r) {
      fcntl $self->{fh}, &Fcntl::F_SETFL, &Fcntl::O_NONBLOCK
         or die "fcntl(O_NONBLOCK): $!";
      $self->{w} = Coro::Event->io(fh => $self->{fh}, parked => 1),
   }
   $r;
}

sub CLOSE {
   my $self = shift;
   $self->{rb} =
   $self->{wb} = "";
   delete $self->{w};
   delete $self->{rw};
   delete $self->{ww};
   close $self->{fh};
}

sub WRITE {
   my $self = $_[0];
   my $len = defined $_[2] ? $_[2] : length $_[1];
   my $ofs = $_[3];
   my $res = 0;

   while () {
      my $r = syswrite $self->{fh}, $_[1], $len, $ofs;
      if (defined $r) {
         $len -= $r;
         $ofs += $r;
         $res += $r;
         last unless $len;
      } elsif ($! != Errno::EAGAIN) {
         last;
      }
      ($self->{ww} ||= Coro::Event->io(fd => $self->{fh}, poll => Event::Watcher::R))->next;
   }

   return $res;
}

sub READ {
   my $self = $_[0];
   my $len = $_[2];
   my $ofs = $_[3];
   my $res = 0;

   while () {
      my $r = sysread $self->{fh}, $_[1], $len, $ofs;
      if (defined $r) {
         $len -= $r;
         $ofs += $r;
         $res += $r;
         last unless $len && $r;
      } elsif ($! != Errno::EAGAIN) {
         last;
      }
      ($self->{rw} ||= Coro::Event->io(fd => $self->{fh}, poll => Event::Watcher::R))->next;
   }

   return $res;
}

sub READLINE {
   my $self = shift;

   while() {
      my $pos = index $self->{rb}, $/;
      if ($pos >= 0) {
         $pos += length $/;
         my $res = substr $self->{rb}, 0, $pos;
         substr ($self->{rb}, 0, $pos) = "";
         return $res;
      }
      my $r = sysread $self->{fh}, $self->{rb}, 8192, length $self->{rb};
      if (defined $r) {
         return undef unless $r;
      } elsif ($! == Errno::EAGAIN) {
         ($self->{rw} ||= Coro::Event->io(fd => $self->{fh}, poll => Event::Watcher::R))->next;
      } else {
         return undef;
      }
   }
}

1;

=head1 BUGS

 - Perl's IO-Handle model is THE bug.
 - READLINE cannot be mixed with other forms of input.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

