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

$VERSION = 1.9;

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

Signals are not reliable, so this function might return
spuriously. Always test for the condition you are waiting on.

=item $status = $s->timed_wait ($timeout)

Like C<wait>, but returns false if no signal happens within $timeout
seconds, otherwise true.

See C<wait> for reliability concerns.

=cut

sub wait {
   unless ($_[0][0]) {
      push @{$_[0][1]}, $Coro::current;
      &Coro::schedule;
   }
   $_[0][0] = 0;
}

sub timed_wait {
   unless ($_[0][0]) {
      require Coro::Timer;
      my $timeout = Coro::Timer::timeout($_[1]);

      push @{$_[0][1]}, $Coro::current;
      &Coro::schedule;

      return 0 if $timeout;
   }

   $_[0][0] = 0;

   1
}

=item $s->send

Send the signal, waking up I<one> waiting process or remember the signal
if no process is waiting.

=cut

sub send {
   $_[0][0] = 1;
   (shift @{$_[0][1]})->ready if @{$_[0][1]};
}

=item $s->broadcast

Send the signal, waking up I<all> waiting process. If no process is
waiting the signal is lost.

=cut

sub broadcast {
   if (my $waiters = delete $_[0][1]) {
      $_->ready for @$waiters;
   }
}

=item $s->awaited

Return true when the signal is being awaited by some process.

=cut

sub awaited {
   ! ! @{$_[0][1]}
}

1;

=back

=head1 BUGS

This implementation is not currently very robust when the process is woken
up by other sources, i.e. C<wait> might return early.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

