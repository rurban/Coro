=head1 NAME

Coro::Handle - non-blocking io with a blocking interface.

=head1 SYNOPSIS

 use Coro::Handle;

=head1 DESCRIPTION

This module implements io-handles in a coroutine-compatible way, that is,
other coroutines can run while reads or writes block on the handle. It
does NOT inherit from IO::Handle but uses tied objects.

=over 4

=cut

package Coro::Handle;

use Errno ();
use base 'Exporter';

$VERSION = 0.13;

@EXPORT = qw(unblock);

=item $fh = new_from_fh Coro::Handle $fhandle [, arg => value...]

Create a new non-blocking io-handle using the given
perl-filehandle. Returns undef if no fhandle is given. The only other
supported argument is "timeout", which sets a timeout for each operation.

=cut

sub new_from_fh {
   my $class = shift;
   my $fh = shift or return;
   my $self = do { local *Coro::Handle };

   my ($package, $filename, $line) = caller;
   $filename =~ s/^.*[\/\\]//;

   tie $self, Coro::Handle::FH, fh => $fh, desc => "$filename:$line", @_;

   my $_fh = select bless \$self, $class; $| = 1; select $_fh;
}

=item $fh = unblock $fh

This is a convinience function that just calls C<new_from_fh> on the given
filehandle. Use it to replace a normal perl filehandle by a non-blocking
equivalent.

=cut

sub unblock($) {
   new_from_fh Coro::Handle $_[0];
}

sub read	{ read     $_[0], $_[1], $_[2], $_[3] }
sub sysread	{ sysread  $_[0], $_[1], $_[2], $_[3] }
sub syswrite	{ syswrite $_[0], $_[1], $_[2], $_[3] }

=item $fh->writable, $fh->readable

Wait until the filehandle is readable or writable (and return true) or
until an error condition happens (and return false).

=cut

sub readable	{ tied(${$_[0]})->readable }
sub writable	{ tied(${$_[0]})->writable }

=item $fh->readline([$terminator])

Like the builtin of the same name, but allows you to specify the input
record separator in a coroutine-safe manner (i.e. not using a global
variable).

=cut

sub readline	{ tied(${+shift})->READLINE(@_) }

=item $fh->autoflush([...])

Always returns true, arguments are being ignored (exists for compatibility
only).

=cut

sub autoflush	{ !0 }

package Coro::Handle::FH;

use Fcntl ();
use Errno ();

use Coro::Event;
use Event::Watcher qw(R W E);

use base 'Tie::Handle';

sub TIEHANDLE {
   my $class = shift;

   my $self = bless {
      rb => "",
      wb => "",
      @_,
   }, $class;

   fcntl $self->{fh}, &Fcntl::F_SETFL, &Fcntl::O_NONBLOCK
      or die "fcntl(O_NONBLOCK): $!";

   $self;
}

sub OPEN {
   my $self = shift;
   $self->CLOSE;
   my $r = @_ == 2 ? open $self->{fh}, $_[0], $_[1]
                   : open $self->{fh}, $_[0], $_[1], $_[2];
   if ($r) {
      fcntl $self->{fh}, &Fcntl::F_SETFL, &Fcntl::O_NONBLOCK
         or die "fcntl(O_NONBLOCK): $!";
   }
   $r;
}

sub CLOSE {
   my $self = shift;
   $self->{rb} =
   $self->{wb} = "";
   (delete $self->{rw})->cancel if $self->{rw};
   (delete $self->{ww})->cancel if $self->{ww};
   close $self->{fh};
}

sub writable {
   ($_[0]->{ww} ||= Coro::Event->io(
      fd      => $_[0]->{fh},
      desc    => "$_[0]->{desc} WW",
      timeout => $_[0]->{timeout},
      poll    => W+E,
   ))->next->got & W;
}

sub readable {
   ($_[0]->{rw} ||= Coro::Event->io(
      fd      => $_[0]->{fh},
      desc    => "$_[0]->{desc} RW",
      timeout => $_[0]->{timeout},
      poll    => R+E,
   ))->next->got & R;
}

sub WRITE {
   my $self = $_[0];
   my $len = defined $_[2] ? $_[2] : length $_[1];
   my $ofs = $_[3];
   my $res = 0;

   while() {
      my $r = syswrite $self->{fh}, $_[1], $len, $ofs;
      if (defined $r) {
         $len -= $r;
         $ofs += $r;
         $res += $r;
         last unless $len;
      } elsif ($! != Errno::EAGAIN) {
         last;
      }
      last unless $self->writable;
   }

   return $res;
}

sub READ {
   my $self = $_[0];
   my $len = $_[2];
   my $ofs = $_[3];
   my $res = 0;

   # first deplete the read buffer
   if (exists $self->{rb}) {
      my $l = length $self->{rb};
      if ($l <= $len) {
         substr($_[1], $ofs) = delete $self->{rb};
         $len -= $l;
         $res += $l;
         return $res unless $len;
      } else {
         substr($_[1], $ofs) = substr($self->{rb}, 0, $len);
         substr($self->{rb}, 0, $len) = "";
         return $len;
      }
   }

   while() {
      my $r = sysread $self->{fh}, $_[1], $len, $ofs;
      if (defined $r) {
         $len -= $r;
         $ofs += $r;
         $res += $r;
         last unless $len && $r;
      } elsif ($! != Errno::EAGAIN) {
         last;
      }
      last unless $self->readable;
   }

   return $res;
}

sub READLINE {
   my $self = shift;
   my $irs = @_ ? shift : $/;

   while() {
      my $pos = index $self->{rb}, $irs;
      if ($pos >= 0) {
         $pos += length $irs;
         my $res = substr $self->{rb}, 0, $pos;
         substr ($self->{rb}, 0, $pos) = "";
         return $res;
      }
      my $r = sysread $self->{fh}, $self->{rb}, 8192, length $self->{rb};
      if (defined $r) {
         return undef unless $r;
      } elsif ($! != Errno::EAGAIN || !$self->readable) {
         return undef;
      }
   }
}

sub DESTROY {
   &CLOSE;
}

1;

=head1 BUGS

 - Perl's IO-Handle model is THE bug.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

