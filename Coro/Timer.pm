=head1 NAME

Coro::Timer - simple timer package, independent of used event loops

=head1 SYNOPSIS

 use Coro::Timer qw(sleep timeout);
 # nothing exported by default

 sleep 10;

=head1 DESCRIPTION

This package implements a simple timer callback system which works
independent of the event loop mechanism used. If no event mechanism is
used, it is emulated. The C<Coro::Event> module overwrites functions with
versions better suited.

This module is not subclassable.

=over 4

=cut

package Coro::Timer;

BEGIN { eval { require warnings } && warnings->unimport ("uninitialized") }

use Carp ();
use Exporter;

use Coro ();

BEGIN {
   eval "use Time::HiRes 'time'";
}

$VERSION = 1.0;
@EXPORT_OK = qw(timeout sleep);

=item $flag = timeout $seconds;

This function will wake up the current coroutine after $seconds
seconds and sets $flag to true (it is false initially).  If $flag goes
out of scope earlier nothing happens. This is used to implement the
C<timed_down>, C<timed_wait> etc. primitives. It is used like this:

   sub timed_wait {
      my $timeout = Coro::Timer::timeout 60;

      while (condition false) {
         schedule; # wait until woken up or timeout
         return 0 if $timeout; # timed out
      }
      return 1; # condition satisfied
   }

=cut

# deep magic, expecially the double indirection :(:(
sub timeout($) {
   my $self = \\my $timer;
   my $current = $Coro::current;
   $timer = _new_timer(time + $_[0], sub {
      undef $timer; # set flag
      $current->ready;
   });
   bless $self, Coro::timeout::;
}

package Coro::timeout;

sub bool    {
   !${${$_[0]}}
}

sub DESTROY { 
   ${${$_[0]}}->cancel;
   undef ${${$_[0]}}; # without this it leaks like hell. breaks the circular reference inside the closure
}

use overload 'bool' => \&bool, '0+' => \&bool;

package Coro::Timer;

=item sleep $seconds

This function works like the built-in sleep, except maybe more precise
and, most important, without blocking other coroutines.

=cut

sub sleep {
   my $current = $Coro::current;
   my $timer = _new_timer(time + $_[0], sub { $current->ready });
   Coro::schedule;
   $timer->cancel;
}

=item $timer = new Coro::Timer at/after => xxx, cb => \&yyy;

Create a new timer.

=cut

sub new {
   my $class = shift;
   my %arg = @_;

   $arg{at} = time + delete $arg{after} if exists $arg{after};

   _new_timer($arg{at}, $arg{cb});
}

my $timer;
my @timer;

unless ($override) {
   $override = 1;
   *_new_timer = sub {
      my $self = bless [$_[0], $_[1]], Coro::Timer::simple;

      # my version of rapid prototyping. guys, use a real event module!
      @timer = sort { $a->[0] cmp $b->[0] } @timer, $self;

      unless ($timer) {
         $timer = new Coro sub {
            my $NOW = time;
            while (@timer) {
               Coro::cede;
               if ($NOW >= $timer[0][0]) {
                  my $next = shift @timer;
                  $next->[1] and $next->[1]->();
               } else {
                  select undef, undef, undef, $timer[0][0] - $NOW;
                  $NOW = time;
               }
            };
            undef $timer;
         };
         $timer->prio(Coro::PRIO_MIN);
         $timer->ready;
      }

      $self;
   };

   *Coro::Timer::simple::cancel = sub {
      @{$_[0]} = ();
   };
}

=item $timer->cancel

Cancel the timer (the callback will no longer be called). This method MUST
be called to remove the timer from memory, otherwise it will never be
freed!

=cut

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

