=head1 NAME

Coro::AnyEvent - integrate threads into AnyEvent

=head1 SYNOPSIS

 use Coro;
 use Coro::AnyEvent;

 # use coro within an AnyEvent environment

=head1 DESCRIPTION

When one naively starts to use threads in Perl, one will quickly run
into the problem that threads that block on a syscall (sleeping,
reading from a socket etc.) will block all threads.

If one then uses an event loop, the problem is that the event loop has
no knowledge of threads and will not run them before it polls for new
events, again blocking the whole process.

This module integrates threads into any event loop supported by
AnyEvent, combining event-based programming with coroutine-based
programming in a natural way.

All you have to do is C<use Coro::AnyEvent>, run the event loop of your
choice in some thread and then you can run threads freely.

=head1 USAGE

This module autodetects the event loop used (by relying on L<AnyEvent>)
and will either automatically defer to the high-performance L<Coro::EV> or
L<Coro::Event> modules, or will use a generic integration into any event
loop supported by L<AnyEvent>.

The effect on your threads (explained in more detail below) will be that
threads of the same or higher priority than the thread running the event
loop will get as much CPU time as they want. If none exist, then threads
of lower priority will also run, but after each of their time slices, the
event loop will run to check for new events.

That means that threads of equal or higher priority will starve the event
system unless they explicitly wait for an event, while those of lower
priority will coexist with the event loop itself.

For this reason, it is often beneficial to run the actual event loop at
slightly elevated priority:

   $Coro::current->nice (-1);
   AnyEvent->loop;

Also note that you actually I<have to run> an event loop for this
priority scheme to work, as neither Coro::AnyEvent nor L<Coro::EV> or
L<Coro::Event> will do that for you - those modules will check for events
only when no other thread is runnable.

The most logical place to run the event loop is usually at the end of the
main program - start some threads, install some event watchers, then run
the event loop of your choice.

=head1 DETAILED DESCRIPTION

Unfortunately, few event loops (basically only L<EV> and L<Event>)
support the kind of integration required for smooth operations well, and
consequently, AnyEvent cannot completely offer the functionality required
by this module, so we need to improvise.

Here is what this module does when it has to work with other event loops:

=over 4

=item * run ready threads before blocking the process

Each time a thread is put into the ready queue (and there are no other
threads in the ready queue), a timer with an C<after> value of C<0> is
registered with AnyEvent.

This creates something similar to an I<idle> watcher, i.e. a watcher
that keeps the event loop from blocking but still polls for new
events. (Unfortunately, some badly designed event loops (e.g. Event::Lib)
don't support a timeout of C<0> and will always block for a bit).

The callback for that timer will C<cede> to other threads of the same or
higher priority for as long as such threads exists. This has the effect of
running all threads that have work to do until all threads block to wait
for external events.

If no threads of equal or higher priority are ready, it will cede to any
thread, but only once. This has the effect of running lower-priority
threads as well, but it will not keep higher priority threads from
receiving new events.

The priority used is simply the priority of the thread that runs the event
loop, usually the main program, which usually has a priority of C<0>.

See "USAGE", above, for more details.

=item * provide a suitable idle callback.

In addition to hooking into C<ready>, this module will also provide a
C<$Coro::idle> handler that runs the event loop. It is best not to take
advantage of this too often, as this is rather inefficient, but it should
work perfectly fine.

=item * provide overrides for AnyEvent's condvars

This module installs overrides for AnyEvent's condvars. That is, when
the module is loaded it will provide its own condition variables. This
makes them coroutine-safe, i.e. you can safely block on them from within a
coroutine.

=item * lead to data corruption or worse

As C<unblock_sub> cannot be used by this module (as it is the module
that implements it, basically), you must not call into the event
loop recursively from any coroutine. This is not usually a difficult
restriction to live with, just use condvars, C<unblock_sub> or other means
of inter-coroutine-communications.

If you use a module that supports AnyEvent (or uses the same event loop
as AnyEvent, making the compatible), and it offers callbacks of any kind,
then you must not block in them, either (or use e.g. C<unblock_sub>), see
the description of C<unblock_sub> in the L<Coro> module.

This also means that you should load the module as early as possible,
as only condvars created after this module has been loaded will work
correctly.

=back

=cut

package Coro::AnyEvent;

no warnings;
use strict;

use Coro;
use AnyEvent ();

our $VERSION = 5.132;

#############################################################################
# idle handler

our $IDLE;

#############################################################################
# 0-timeout idle emulation watcher

our $ACTIVITY;

sub _activity {
   $ACTIVITY ||= AnyEvent->timer (after => 0, cb => \&_schedule);
}

Coro::_set_readyhook (\&AnyEvent::detect);

AnyEvent::post_detect {
   unshift @AnyEvent::CondVar::ISA, "Coro::AnyEvent::CondVar";

   Coro::_set_readyhook undef;

   my $model = $AnyEvent::MODEL;

   if ($model eq "AnyEvent::Impl::EV") {
      require Coro::EV;
   } elsif ($model eq "AnyEvent::Impl::Event") {
      require Coro::Event;
   } else {
      Coro::_set_readyhook \&_activity;

      $IDLE = new Coro sub {
         my $one_event = AnyEvent->can ("one_event");
         while () {
            $one_event->();
            Coro::schedule;
         }
      };
      $IDLE->{desc} = "[AnyEvent idle process]";

      $Coro::idle = $IDLE;
   }
};

#############################################################################
# override condvars

package Coro::AnyEvent::CondVar;

sub _send {
   (delete $_[0]{_ae_coro})->ready if $_[0]{_ae_coro};
}

sub _wait {
   while (!$_[0]{_ae_sent}) {
      local $_[0]{_ae_coro} = $Coro::current;
      Coro::schedule;
   }
}

1;

=head1 SEE ALSO

L<AnyEvent>, to see which event loops are supported, L<Coro::EV> and
L<Coro::Event> for more efficient and more correct solutions (they will be
used automatically if applicable).

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

