=head1 NAME

Coro::Signal - coroutine signals (binary semaphores)

=head1 SYNOPSIS

 use Coro::Signal;

 $sig = new Coro::Signal;

 $sig->wait; # wait for signal

 # ... some other "thread"

 $sig->send;

=head1 DESCRIPTION

=over 4

=cut

package Coro::Signal;

use Coro ();

$VERSION = 0.11;

=item $s = new Coro::Signal;

Create a new signal.

=cut

sub new {
   # [flag, [pid's]]
   bless [], $_[0];
}

=item $s->wait

Wait for the signal to occur. Returns immediately if the signal has been
sent before.

=cut

sub wait {
   if ($_[0][0]) {
      $_[0][0] = 0;
   } else {
      push @{$_[0][1]}, $Coro::current;
      Coro::schedule;
   }
}

=item $s->send

Send the signal, waking up I<one> waiting process or remember the signal
if no process is waiting.

=cut

sub send {
   if (@{$_[0][1]}) {
      (shift @{$_[0][1]})->ready;
   } else {
      $_[0][0] = 1;
   }
}

=item $s->broadcast

Send the signal, waking up I<all> waiting process. If no process is
waiting the signal is lost.

=cut

sub broadcast {
   (shift @{$_[0][1]})->ready while @{$_[0][1]};
}

=item $s->awaited

Return true when the signal is beign awaited by some process.

=cut

sub awaited {
   !!@{$_[0][1]};
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

