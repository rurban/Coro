=head1 NAME

Coro::Timer - simple timer package, independent of used event loops

=head1 SYNOPSIS

 use Coro::Timer;

=head1 DESCRIPTION

This package implements a simple timer callback system which works
independent of the event loop mechanism used. If no event mechanism is
used, it is emulated. The C<Coro::Event> module overwrites functions with
versions better suited.

=over 4

=cut

package Coro::Timer;

no warnings qw(uninitialized);

use Carp ();

use Coro ();

BEGIN { eval "use Time::HiRes 'time'" }

$VERSION = 0.52;

=item $timer = new Coro::Timer at/after => xxx, cb => \&yyy;

Create a new timer.

=cut

sub new {
   my $class = shift;
   my %arg = @_;

   $arg{at} = time + delete $arg{after} if exists $arg{after};

   _new_timer($class, $arg{at}, $arg{cb});
}

my $timer;
my @timer;

unless ($override) {
   $override = 1;
   *_new_timer = sub {
      my $self = bless [$_[1], $_[2]], $_[0];

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
            print "hihohihoh ($timer, $timer->{_coro_state})\n";
            print "hihohihoy $Coro::current\n";
            use Devel::Peek;
            #Dump($timer);
            undef $timer;
            print "hihohihox $Coro::current\n";
         };
         $timer->prio(Coro::PRIO_MIN);
         $timer->ready;
      }

      $self;
   };

   *cancel = sub {
      undef $_[0][1];
   };
}

=item $timer->cancel

Cancel the timer (the callback will no longer be called).

=cut

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

