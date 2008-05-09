=head1 NAME

Coro::AnyEvent - try to integrate coroutines into AnyEvent

=head1 SYNOPSIS

 use Coro;
 use Coro::AnyEvent;

 # use coro within an AnyEvent environment

=head1 INTRODUCTION

When one naively starts to use coroutines in Perl, one will quickly run
into the problem that coroutines that block on a syscall (sleeping,
reading from a socket etc.) will block all coroutines.

If one then uses an event loop, the problem is that the event loop has
no knowledge of coroutines and will not run them before it polls for new
events, again blocking the whole process.

This module integrates coroutines into any event loop supported by
AnyEvent, combining event-based programming with coroutine-based
programming in a natural way.

All you have to do is C<use Coro::AnyEvent> and then you can run a
coroutines freely.

=head1 DESCRIPTION

This module autodetects the event loop used (by relying on L<AnyEvent>)
and will either automatically defer to the high-performance L<Coro::EV> or
L<Coro::Event> modules, or will use a generic integration into any event
loop supported by L<AnyEvent>.

Unfortunately, few event loops (basically only L<EV> and L<Event>) support
this kind of integration well, and therefore AnyEvent cannot offer the
required functionality.

Here is what this module does when it has to work with other event loops:

Each time a coroutine is put into the ready queue (and there are no other
coroutines in the ready queue), a timer with an C<after> value of C<0> is
registered with AnyEvent.

This creates something similar to an I<idle> watcher, i.e. a watcher
that keeps the event loop from blocking but still polls for new
events. (Unfortunately, some badly designed event loops (e.g. Event::Lib)
don't support a timeout of C<0> and will always block for a bit).

The callback for that timer will C<cede> to other coroutines of the same
or higher priority for as long as such coroutines exists. This has the
effect of running all coroutines that have work to do will all coroutines
block to wait for external events.

If no coroutines of equal or higher priority are ready, it will cede
to any coroutine, but only once. This has the effect of running
lower-priority coroutines as well, but it will not keep higher priority
coroutines from receiving new events.

The priority used is simply the priority of the coroutine that runs the
event loop, usually the main program, and the priority is usually C<0>.

As C<unblock_sub> cannot be used, you must not call into the event loop
recursively (e.g. you must not use AnyEvent condvars in a blocking
way). This restriction will be lifted in a later version of AnyEvent and
Coro.

In addition to hooking into C<ready>, this module will also provide a
C<$Coro::idle> handler that runs the event loop. It is best not to rely on
this.

=cut

package Coro::AnyEvent;

no warnings;
use strict;

use Coro;
use AnyEvent ();

our $VERSION = '2.2';

our $IDLE = new Coro sub {
   while () {
      AnyEvent->one_event;
      &Coro::schedule;
   }
};
$IDLE->{desc} = "[AnyEvent idle process]";

our $ACTIVITY;

sub _activity {
   $ACTIVITY ||= AnyEvent->timer (after => 0, cb => \&_schedule);
}

sub _detect {
   my $model = AnyEvent::detect;

   warn "detect $model\n";#d#

   if ($model eq "AnyEvent::Impl::EV" || $model eq "AnyEvent::Impl::CoroEV") {
      require Coro::EV;
      Coro::_set_readyhook undef;
   } elsif ($model eq "AnyEvent::Impl::Event" || $model eq "AnyEvent::Impl::CoroEvent") {
      require Coro::Event;
      Coro::_set_readyhook undef;
   } else {
      Coro::_set_readyhook \&_activity;
      $Coro::idle = sub {
         local $ACTIVITY = 1; # hack to keep it from being set
         $IDLE->ready;
      };
   }
}

Coro::_set_readyhook \&_detect;

1;

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

