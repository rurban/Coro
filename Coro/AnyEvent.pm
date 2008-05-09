=head1 NAME

Coro::AnyEvent - try to integrate coroutines into AnyEvent

=head1 SYNOPSIS

 use Coro;
 use Coro::AnyEvent;

 # use coro within an Anyevent environment

=head1 DESCRIPTION

TODO:

This module does two things: First, it offers some utility functions that
might be useful for coroutines, and secondly, it integrates Coro into the
EV main loop:

Before the process blocks (in EV::loop) to wait for events, this module
will schedule and run all ready (= runnable) coroutines of the same or
higher priority. After that, it will cede once to a coroutine of lower
priority, then continue in the event loop.

That means that coroutines with the same or higher pripority as the
coroutine running the main loop will inhibit event processing, while
coroutines of lower priority will get the CPU, but cannot completeley
inhibit event processing.

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

