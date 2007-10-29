=head1 NAME

Coro::EV - do events the coro-way

=head1 SYNOPSIS

 use Coro;
 use Coro::EV;

 loop;

=head1 DESCRIPTION

=head1 FUNCTIONS

=over 4

=cut

package Coro::EV;

no warnings;

use Carp;
no warnings;

use Coro;
use Coro::Timer;

use EV ();
use XSLoader;

BEGIN {
   our $VERSION = '2.1';

   local $^W = 0; # avoid redefine warning for Coro::ready;
   XSLoader::load __PACKAGE__, $VERSION;
}

=cut

=item

=item Coro::EV::loop

You have to call this function instead of EV::loop, EV::dispatch and
similar functions. EV is not generic enough to let Coro hook into yet, so
you have to use those replacement functions.

=item $revents = Coro::EV::timed_io_once $fd, $events, $timeout

Blocks the coroutine until either the given event set has occured on the
fd, or the timeout has been reached (if timeout is zero, there is no
timeout). Returns the received flags.

=item Coro::EV::timer_once $after

Blocks the coroutine for at least C<$after> seconds.

=cut

# relatively inefficient
our $ev_idle = new Coro sub {
   while () {
      EV::loop EV::LOOP_ONESHOT;
      &Coro::schedule;
   }
};
$ev->{desc} = "[EV idle process]";

$Coro::idle = sub { $ev_idle->ready };

sub timed_io_once($$;$) {
   &_timed_io_once;
   do { &Coro::schedule } while !$#_;
   pop
}

sub timer_once($) {
   &_timer_once;
   do { &Coro::schedule } while !$#_;
   pop
}

#sub timer_abs_once($$) {
#   &_timer_abs_once;
#   do { &Coro::schedule } while !$#_;
#   pop
#}

1;

=back

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

