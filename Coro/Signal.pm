=head1 NAME

Coro::Signal - coroutine signals (binary semaphores)

=head1 SYNOPSIS

 use Coro::Signal;

 $sig = new Coro::Signal;

 $sig->wait; # wait for signal

 # ... some other "thread"

 $sig->send;

=head1 DESCRIPTION

This module implements signal/binary semaphores/condition variables
(basically all the same thing). You can wait for a signal to occur or send
it, in which case it will wake up one waiter, or it can be broadcast,
waking up all waiters.

=over 4

=cut

package Coro::Signal;

BEGIN { eval { require warnings } && warnings->unimport ("uninitialized") }

use Coro ();

$VERSION = 0.8;

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

=item $status = $s->timed_wait($timeout)

Like C<wait>, but returns false if no signal happens within $timeout
seconds, otherwise true.

=cut

sub wait {
   if ($_[0][0]) {
      $_[0][0] = 0;
   } else {
      push @{$_[0][1]}, $Coro::current;
      Coro::schedule;
   }
}

sub timed_wait {
   if ($_[0][0]) {
      $_[0][0] = 0;
      return 1;
   } else {
      require Coro::Timer;
      my $timeout = Coro::Timer::timeout($_[1]);
      push @{$_[0][1]}, $Coro::current;
      Coro::schedule;
      return !$timeout;
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

Return true when the signal is being awaited by some process.

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

