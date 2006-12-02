=head1 NAME

Coro - coroutine process abstraction

=head1 SYNOPSIS

 use Coro;

 async {
    # some asynchronous thread of execution
 };

 # alternatively create an async coroutine like this:

 sub some_func : Coro {
    # some more async code
 }

 cede;

=head1 DESCRIPTION

This module collection manages coroutines. Coroutines are similar to
threads but don't run in parallel.

In this module, coroutines are defined as "callchain + lexical variables
+ @_ + $_ + $@ + $^W + C stack), that is, a coroutine has it's own
callchain, it's own set of lexicals and it's own set of perl's most
important global variables.

=cut

package Coro;

use strict;
no warnings "uninitialized";

use Coro::State;

use base qw(Coro::State Exporter);

our $idle;    # idle handler
our $main;    # main coroutine
our $current; # current coroutine

our $VERSION = '3.0';

our @EXPORT = qw(async cede schedule terminate current unblock_sub);
our %EXPORT_TAGS = (
      prio => [qw(PRIO_MAX PRIO_HIGH PRIO_NORMAL PRIO_LOW PRIO_IDLE PRIO_MIN)],
);
our @EXPORT_OK = @{$EXPORT_TAGS{prio}};

{
   my @async;
   my $init;

   # this way of handling attributes simply is NOT scalable ;()
   sub import {
      no strict 'refs';

      Coro->export_to_level (1, @_);

      my $old = *{(caller)[0]."::MODIFY_CODE_ATTRIBUTES"}{CODE};
      *{(caller)[0]."::MODIFY_CODE_ATTRIBUTES"} = sub {
         my ($package, $ref) = (shift, shift);
         my @attrs;
         for (@_) {
            if ($_ eq "Coro") {
               push @async, $ref;
               unless ($init++) {
                  eval q{
                     sub INIT {
                        &async(pop @async) while @async;
                     }
                  };
               }
            } else {
               push @attrs, $_;
            }
         }
         return $old ? $old->($package, $ref, @attrs) : @attrs;
      };
   }

}

=over 4

=item $main

This coroutine represents the main program.

=cut

$main = new Coro;

=item $current (or as function: current)

The current coroutine (the last coroutine switched to). The initial value
is C<$main> (of course).

This variable is B<strictly> I<read-only>. It is provided for performance
reasons. If performance is not essentiel you are encouraged to use the
C<Coro::current> function instead.

=cut

# maybe some other module used Coro::Specific before...
$main->{specific} = $current->{specific}
   if $current;

_set_current $main;

sub current() { $current }

=item $idle

A callback that is called whenever the scheduler finds no ready coroutines
to run. The default implementation prints "FATAL: deadlock detected" and
exits, because the program has no other way to continue.

This hook is overwritten by modules such as C<Coro::Timer> and
C<Coro::Event> to wait on an external event that hopefully wake up a
coroutine so the scheduler can run it.

Please note that if your callback recursively invokes perl (e.g. for event
handlers), then it must be prepared to be called recursively.

=cut

$idle = sub {
   print STDERR "FATAL: deadlock detected\n";
   exit (51);
};

# this coroutine is necessary because a coroutine
# cannot destroy itself.
my @destroy;
my $manager; $manager = new Coro sub {
   while () {
      # by overwriting the state object with the manager we destroy it
      # while still being able to schedule this coroutine (in case it has
      # been readied multiple times. this is harmless since the manager
      # can be called as many times as neccessary and will always
      # remove itself from the runqueue
      while (@destroy) {
         my $coro = pop @destroy;
         $coro->{status} ||= [];
         $_->ready for @{delete $coro->{join} || []};

         # the next line destroys the coro state, but keeps the
         # coroutine itself intact (we basically make it a zombie
         # coroutine that always runs the manager thread, so it's possible
         # to transfer() to this coroutine).
         $coro->_clone_state_from ($manager);
      }
      &schedule;
   }
};

# static methods. not really.

=back

=head2 STATIC METHODS

Static methods are actually functions that operate on the current coroutine only.

=over 4

=item async { ... } [@args...]

Create a new asynchronous coroutine and return it's coroutine object
(usually unused). When the sub returns the new coroutine is automatically
terminated.

Calling C<exit> in a coroutine will not work correctly, so do not do that.

When the coroutine dies, the program will exit, just as in the main
program.

   # create a new coroutine that just prints its arguments
   async {
      print "@_\n";
   } 1,2,3,4;

=cut

sub async(&@) {
   my $pid = new Coro @_;
   $pid->ready;
   $pid
}

=item schedule

Calls the scheduler. Please note that the current coroutine will not be put
into the ready queue, so calling this function usually means you will
never be called again unless something else (e.g. an event handler) calls
ready.

The canonical way to wait on external events is this:

   {
      # remember current coroutine
      my $current = $Coro::current;

      # register a hypothetical event handler
      on_event_invoke sub {
         # wake up sleeping coroutine
         $current->ready;
         undef $current;
      };

      # call schedule until event occured.
      # in case we are woken up for other reasons
      # (current still defined), loop.
      Coro::schedule while $current;
   }

=item cede

"Cede" to other coroutines. This function puts the current coroutine into the
ready queue and calls C<schedule>, which has the effect of giving up the
current "timeslice" to other coroutines of the same or higher priority.

=item terminate [arg...]

Terminates the current coroutine with the given status values (see L<cancel>).

=cut

sub terminate {
   $current->cancel (@_);
}

=back

# dynamic methods

=head2 COROUTINE METHODS

These are the methods you can call on coroutine objects.

=over 4

=item new Coro \&sub [, @args...]

Create a new coroutine and return it. When the sub returns the coroutine
automatically terminates as if C<terminate> with the returned values were
called. To make the coroutine run you must first put it into the ready queue
by calling the ready method.

Calling C<exit> in a coroutine will not work correctly, so do not do that.

=cut

sub _run_coro {
   terminate &{+shift};
}

sub new {
   my $class = shift;

   $class->SUPER::new (\&_run_coro, @_)
}

=item $success = $coroutine->ready

Put the given coroutine into the ready queue (according to it's priority)
and return true. If the coroutine is already in the ready queue, do nothing
and return false.

=item $is_ready = $coroutine->is_ready

Return wether the coroutine is currently the ready queue or not,

=item $coroutine->cancel (arg...)

Terminates the given coroutine and makes it return the given arguments as
status (default: the empty list).

=cut

sub cancel {
   my $self = shift;
   $self->{status} = [@_];
   push @destroy, $self;
   $manager->ready;
   &schedule if $current == $self;
}

=item $coroutine->join

Wait until the coroutine terminates and return any values given to the
C<terminate> or C<cancel> functions. C<join> can be called multiple times
from multiple coroutine.

=cut

sub join {
   my $self = shift;
   unless ($self->{status}) {
      push @{$self->{join}}, $current;
      &schedule;
   }
   wantarray ? @{$self->{status}} : $self->{status}[0];
}

=item $oldprio = $coroutine->prio ($newprio)

Sets (or gets, if the argument is missing) the priority of the
coroutine. Higher priority coroutines get run before lower priority
coroutines. Priorities are small signed integers (currently -4 .. +3),
that you can refer to using PRIO_xxx constants (use the import tag :prio
to get then):

   PRIO_MAX > PRIO_HIGH > PRIO_NORMAL > PRIO_LOW > PRIO_IDLE > PRIO_MIN
       3    >     1     >      0      >    -1    >    -3     >    -4

   # set priority to HIGH
   current->prio(PRIO_HIGH);

The idle coroutine ($Coro::idle) always has a lower priority than any
existing coroutine.

Changing the priority of the current coroutine will take effect immediately,
but changing the priority of coroutines in the ready queue (but not
running) will only take effect after the next schedule (of that
coroutine). This is a bug that will be fixed in some future version.

=item $newprio = $coroutine->nice ($change)

Similar to C<prio>, but subtract the given value from the priority (i.e.
higher values mean lower priority, just as in unix).

=item $olddesc = $coroutine->desc ($newdesc)

Sets (or gets in case the argument is missing) the description for this
coroutine. This is just a free-form string you can associate with a coroutine.

=cut

sub desc {
   my $old = $_[0]{desc};
   $_[0]{desc} = $_[1] if @_ > 1;
   $old;
}

=back

=head2 UTILITY FUNCTIONS

=over 4

=item unblock_sub { ... }

This utility function takes a BLOCK or code reference and "unblocks" it,
returning the new coderef. This means that the new coderef will return
immediately without blocking, returning nothing, while the original code
ref will be called (with parameters) from within its own coroutine.

The reason this fucntion exists is that many event libraries (such as the
venerable L<Event|Event> module) are not coroutine-safe (a weaker form
of thread-safety). This means you must not block within event callbacks,
otherwise you might suffer from crashes or worse.

This function allows your callbacks to block by executing them in another
coroutine where it is safe to block. One example where blocking is handy
is when you use the L<Coro::AIO|Coro::AIO> functions to save results to
disk.

In short: simply use C<unblock_sub { ... }> instead of C<sub { ... }> when
creating event callbacks that want to block.

=cut

our @unblock_pool;
our @unblock_queue;
our $UNBLOCK_POOL_SIZE = 2;

sub unblock_handler_ {
   while () {
      my ($cb, @arg) = @{ delete $Coro::current->{arg} };
      $cb->(@arg);

      last if @unblock_pool >= $UNBLOCK_POOL_SIZE;
      push @unblock_pool, $Coro::current;
      schedule;
   }        
}           

our $unblock_scheduler = async {
   while () {
      while (my $cb = pop @unblock_queue) {
         my $handler = (pop @unblock_pool or new Coro \&unblock_handler_);
         $handler->{arg} = $cb;
         $handler->ready;
         cede;
      }

      schedule;
   }
};

sub unblock_sub(&) {
   my $cb = shift;

   sub {
      push @unblock_queue, [$cb, @_];
      $unblock_scheduler->ready;
   }
}

=back

=cut

1;

=head1 BUGS/LIMITATIONS

 - you must make very sure that no coro is still active on global
   destruction. very bad things might happen otherwise (usually segfaults).

 - this module is not thread-safe. You should only ever use this module
   from the same thread (this requirement might be losened in the future
   to allow per-thread schedulers, but Coro::State does not yet allow
   this).

=head1 SEE ALSO

Support/Utility: L<Coro::Cont>, L<Coro::Specific>, L<Coro::State>, L<Coro::Util>.

Locking/IPC: L<Coro::Signal>, L<Coro::Channel>, L<Coro::Semaphore>, L<Coro::SemaphoreSet>, L<Coro::RWLock>.

Event/IO: L<Coro::Timer>, L<Coro::Event>, L<Coro::Handle>, L<Coro::Socket>, L<Coro::Select>.

Embedding: L<Coro:MakeMaker>

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

