=head1 NAME

Coro::Event - do events the coro-way

=head1 SYNOPSIS

 use Coro;
 use Coro::Event;

 sub keyboard : Coro {
    my $w = Coro::Event->io(fd => *STDIN, poll => 'r');
    while() {
       print "cmd> ";
       my $ev = $w->next; my $cmd = <STDIN>;
       unloop unless $cmd ne "";
       print "data> ";
       my $ev = $w->next; my $data = <STDIN>;
    }
 }

 &loop;

=head1 DESCRIPTION

This module enables you to create programs using the powerful Event modell
(and module), while retaining the linear style known from simple or
threaded programs.

This module provides a method and a function for every watcher type
(I<flavour>) (see L<Event>). The only difference between these and the
watcher constructors from Event is that you do not specify a callback
function - it will be managed by this module.

Your application should just create all necessary coroutines and then call
Coro::Event->main.

=over 4

=cut

package Coro::Event;

no warnings;

use Carp;

use Event qw(unloop); # we are re-exporting this, cooool!

use base 'Event';
use base 'Exporter';

@EXPORT = qw(loop unloop);

$VERSION = 0.08;

=item $w = Coro::Event->flavour(args...)

Create and return a watcher of the given type.

Examples:

  my $reader = Coro::Event->io(fd => $filehandle, poll => 'r');
  $reader->next;

=cut

=item $w->next

Return the next event of the event queue of the watcher.

=cut

=item do_flavour(args...)

Create a watcher of the given type and immediately call it's next
method. This is less efficient then calling the constructor once and the
next method often, but it does save typing sometimes.

=cut

for my $flavour (qw(idle var timer io signal)) {
   push @EXPORT, "do_$flavour";
   my $new = \&{"Event::$flavour"};
   my $class = "Coro::Event::$flavour";
   @{"${class}::ISA"} = ("Coro::Event", "Event::$flavour");
   my $coronew = sub {
      # how does one do method-call-by-name?
      # my $w = $class->SUPER::$flavour(@_);

      my $w;
      my $q = []; # [$coro, $event]
      $w = $new->(@_, cb => sub {
            $q->[1] = $_[0];
            if ($q->[0]) { # somebody waiting?
               $q->[0]->ready;
               Coro::schedule;
            } else {
               $w->stop;
            }
      });
      $w->private($q); # using private as attribute is pretty useless...
      bless $w, $class; # reblessing due to broken Event
   };
   *{    $flavour } = $coronew;
   *{"do_$flavour"} = sub {
      unshift @_, $class;
      (&$coronew)->next;
   };
}

sub next {
   my $q = $_[0]->private;
   croak "only one coroutine can wait for an event" if $q->[0];
   if (!$q->[1]) { # no event waiting?
      local $q->[0] = $Coro::current;
      Coro::schedule;
   } else {
      $_[0]->again;
   }
   delete $q->[1];
}

=item $result = loop([$timeout])

This is the version of C<loop> you should use instead of C<Event::loop>
when using this module - it will ensure correct scheduling in the presence
of events.

=cut

sub loop(;$) {
   local $Coro::idle = $Coro::current;
   Coro::schedule; # become idle task, which is implicitly ready
   &Event::loop;
}

=item unloop([$result])

Same as Event::unloop (provided here for your convinience only).

=cut

1;

=head1 BUGS

This module is implemented straightforward using Coro::Channel and thus
not as efficient as possible.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

