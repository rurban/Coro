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
       print "data> ";
       my $ev = $w->next; my $data = <STDIN>;
    }
 }

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

use Coro::Channel;

use base 'Event';
use base 'Exporter';

$VERSION = 0.01;

=item Coro::Event->flavour(args...)

Create and return a watcher of the given type.

Examples:

  my $reader = Coro::Event->io(fd => $filehandle, poll => 'r');
  $reader->next;

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

      my $q = new Coro::Channel 0;
      my $w;
      $w = $new->(@_, parked => 1, cb => sub { $w->stop; $q->put($_[0]) });
      $w->private($q); # using private as attribute is pretty useless...
      bless $w, $class; # reblessing due to broken Event
   };
   *{    $flavour } = $coronew;
   *{"do_$flavour"} = sub {
      unshift @_, $class;
      (&$coronew)->next;
   };
}

=item $w->next

Return the next event of the event queue of the watcher.

=cut

sub next {
   $_[0]->start;
   $_[0]->private->get;
}

=item Coro::Event->main

=cut

sub main {
   local $Coro::idle = new Coro sub {
      Event::loop;
   };
   Coro::schedule;
}

1;

=head1 BUGS

This module is implemented straightforward using Coro::Channel and thus
not as efficient as possible.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

