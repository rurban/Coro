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

$VERSION = 0.45;

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

sub readable	{ Coro::Handle::FH::readable(tied ${$_[0]}) }
sub writable	{ Coro::Handle::FH::writable(tied ${$_[0]}) }

=item $fh->readline([$terminator])

Like the builtin of the same name, but allows you to specify the input
record separator in a coroutine-safe manner (i.e. not using a global
variable).

=cut

sub readline	{ tied(${+shift})->READLINE(@_) }

=item $fh->autoflush([...])

Always returns true, arguments are being ignored (exists for compatibility
only). Might change in the future.

=cut

sub autoflush	{ !0 }

=item $fh->fileno, $fh->close

Work like their function equivalents.

=cut

sub fileno { tied(${$_[0]})->FILENO }
sub close  { tied(${$_[0]})->CLOSE  }

=item $fh->timeout([...])

The optional agrument sets the new timeout (in seconds) for this
handle. Returns the current (new) value.

C<0> is a valid timeout, use C<undef> to disable the timeout.

=cut

sub timeout {
   my $self = tied(${$_[0]});
   if (@_ > 1) {
      $self->[2] = $_[1];
      $self->[5]->timeout($_[1]) if $self->[5];
      $self->[6]->timeout($_[1]) if $self->[6];
   }
   $self->[2];
}

=item $fh->fh

Returns the "real" (non-blocking) filehandle. Use this if you want to
do operations on the file handle you cannot do using the Coro::Handle
interface.

=cut

sub fh {
   tied(${$_[0]})->{fh};
}

package Coro::Handle::FH;

use Fcntl ();
use Errno ();
use Carp 'croak';

use Coro::Event;
use Event::Watcher qw(R W E);

use base 'Tie::Handle';

# formerly a hash, but we are speed-critical, so try
# to be faster even if it hurts.
#
# 0 FH
# 1 desc
# 2 timeout
# 3 rb
# 4 wb
# 5 rw
# 6 ww

sub TIEHANDLE {
   my $class = shift;
   my %args = @_;

   my $self = bless [], $class;
   $self->[0] = $args{fh};
   $self->[1] = $args{desc};
   $self->[2] = $args{timeout};
   $self->[3] = "";
   $self->[4] = "";

   fcntl $self->[0], &Fcntl::F_SETFL, &Fcntl::O_NONBLOCK
      or croak "fcntl(O_NONBLOCK): $!";

   $self;
}

sub cleanup {
   $_[0][3] = "";
   ($_[0][5])->cancel if exists $_[0][5]; $_[0][5] = undef;

   $_[0][4] = "";
   ($_[0][6])->cancel if exists $_[0][6]; $_[0][6] = undef;
}

sub OPEN {
   &cleanup;
   my $self = shift;
   my $r = @_ == 2 ? open $self->[0], $_[0], $_[1]
                   : open $self->[0], $_[0], $_[1], $_[2];
   if ($r) {
      fcntl $self->[0], &Fcntl::F_SETFL, &Fcntl::O_NONBLOCK
         or croak "fcntl(O_NONBLOCK): $!";
   }
   $r;
}

sub CLOSE {
   &cleanup;
   close $_[0][0];
}

sub DESTROY {
   &cleanup;
}

sub FILENO {
   fileno $_[0][0];
}

sub readable {
   ($_[0][5] ||= Coro::Event->io(
      fd      => $_[0][0],
      desc    => "$_[0][1] R",
      timeout => $_[0][2],
      poll    => R+E,
   ))->next->{Coro::Event}[5] & R;
}

sub writable {
   ($_[0][6] ||= Coro::Event->io(
      fd      => $_[0][0],
      desc    => "$_[0][1] W",
      timeout => $_[0][2],
      poll    => W+E,
   ))->next->{Coro::Event}[5] & W;
}

sub WRITE {
   my $len = defined $_[2] ? $_[2] : length $_[1];
   my $ofs = $_[3];
   my $res = 0;

   while() {
      my $r = syswrite $_[0][0], $_[1], $len, $ofs;
      if (defined $r) {
         $len -= $r;
         $ofs += $r;
         $res += $r;
         last unless $len;
      } elsif ($! != Errno::EAGAIN) {
         last;
      }
      last unless &writable;
   }

   return $res;
}

sub READ {
   my $len = $_[2];
   my $ofs = $_[3];
   my $res = 0;

   # first deplete the read buffer
   if (defined $_[0][3]) {
      my $l = length $_[0][3];
      if ($l <= $len) {
         substr($_[1], $ofs) = $_[0][3]; undef $_[0][3];
         $len -= $l;
         $res += $l;
         return $res unless $len;
      } else {
         substr($_[1], $ofs) = substr($_[0][3], 0, $len);
         substr($_[0][3], 0, $len) = "";
         return $len;
      }
   }

   while() {
      my $r = sysread $_[0][0], $_[1], $len, $ofs;
      if (defined $r) {
         $len -= $r;
         $ofs += $r;
         $res += $r;
         last unless $len && $r;
      } elsif ($! != Errno::EAGAIN) {
         last;
      }
      last unless &readable;
   }

   return $res;
}

sub READLINE {
   my $irs = @_ > 1 ? $_[1] : $/;

   while() {
      my $pos = index $_[0][3], $irs;
      if ($pos >= 0) {
         $pos += length $irs;
         my $res = substr $_[0][3], 0, $pos;
         substr ($_[0][3], 0, $pos) = "";
         return $res;
      }

      my $r = sysread $_[0][0], $_[0][3], 8192, length $_[0][3];
      if (defined $r) {
         return undef unless $r;
      } elsif ($! != Errno::EAGAIN || !&readable) {
         return undef;
      }
   }
}

1;

=head1 BUGS

 - Perl's IO-Handle model is THE bug.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

