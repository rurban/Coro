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

 loop;

=head1 DESCRIPTION

This module enables you to create programs using the powerful Event model
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

no warnings qw(uninitialized);

use Carp;

use Coro;
use Event qw(loop unloop); # we are re-exporting this, cooool!

use base 'Exporter';

@EXPORT = qw(loop unloop sweep reschedule);

BEGIN {
   $VERSION = 0.45;

   local $^W = 0; # avoid redefine warning for Coro::ready
   require XSLoader;
   XSLoader::load Coro::Event, $VERSION;
}

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
   my $type = $flavour eq "io" ? 1 : 0;
   @{"${class}::ISA"} = (Coro::Event::, "Event::$flavour");
   my $coronew = sub {
      # how does one do method-call-by-name?
      # my $w = $class->SUPER::$flavour(@_);

      $_[0] eq Coro::Event::
         or croak "event constructor \"Coro::Event->$flavour\" must be called as a static method";

      my $q = []; # [$coro, $event]
      my $w = $new->(
            desc => $flavour,
            @_,
            parked => 1,
      );
      _install_std_cb($w, $type);
      bless $w, $class; # reblessing due to broken Event
   };
   *{    $flavour } = $coronew;
   *{"do_$flavour"} = sub {
      unshift @_, Coro::Event::;
      my $e = (&$coronew)->next;
      $e->cancel; # $e = $e->w->cancel ($e == $e->w!)
      $e;
   };
}

# double calls to avoid stack-cloning ;()
# is about 10% slower, though.
sub next($) {
   &Coro::schedule if &_next; $_[0];
}

sub Coro::Event::w    { $_[0] }
sub Coro::Event::prio { $_[0]{Coro::Event}[3] }
sub Coro::Event::hits { $_[0]{Coro::Event}[4] }
sub Coro::Event::got  { $_[0]{Coro::Event}[5] }

=item sweep

Similar to Event::one_event and Event::sweep: The idle task is called once
(this has the effect of jumping back into the Event loop once to serve new
events).

The reason this function exists is that you sometimes want to serve events
while doing other work. Calling C<Coro::cede> does not work because
C<cede> implies that the current coroutine is runnable and does not call
into the Event dispatcher.

=cut

sub sweep {
   Event::one_event(0); # for now
}

=item $result = loop([$timeout])

This is the version of C<loop> you should use instead of C<Event::loop>
when using this module - it will ensure correct scheduling in the presence
of events.

=begin comment

Unlike loop's counterpart it is not an error when no watchers are active -
loop silently returns in this case, as if unloop(undef) were called.

=end comment

=cut

# no longer do something special - it's done internally now

#sub loop(;$) {
#   #local $Coro::idle = $Coro::current;
#   #Coro::schedule; # become idle task, which is implicitly ready
#   &Event::loop;
#}

=item unloop([$result])

Same as Event::unloop (provided here for your convinience only).

=cut

$Coro::idle = new Coro sub {
   while () {
      Event::one_event; # inefficient
      Coro::schedule;
   }
};

1;

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

