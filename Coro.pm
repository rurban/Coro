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

This module collection manages coroutines. Coroutines are similar
to threads but don't run in parallel at the same time even on SMP
machines. The specific flavor of coroutine used in this module also
guarantees you that it will not switch between coroutines unless
necessary, at easily-identified points in your program, so locking and
parallel access are rarely an issue, making coroutine programming much
safer than threads programming.

(Perl, however, does not natively support real threads but instead does a
very slow and memory-intensive emulation of processes using threads. This
is a performance win on Windows machines, and a loss everywhere else).

In this module, coroutines are defined as "callchain + lexical variables +
@_ + $_ + $@ + $/ + C stack), that is, a coroutine has its own callchain,
its own set of lexicals and its own set of perls most important global
variables.

=cut

package Coro;

use strict;
no warnings "uninitialized";

use Coro::State;

use base qw(Coro::State Exporter);

our $idle;    # idle handler
our $main;    # main coroutine
our $current; # current coroutine

our $VERSION = '4.0';

our @EXPORT = qw(async async_pool cede schedule terminate current unblock_sub);
our %EXPORT_TAGS = (
      prio => [qw(PRIO_MAX PRIO_HIGH PRIO_NORMAL PRIO_LOW PRIO_IDLE PRIO_MIN)],
);
our @EXPORT_OK = (@{$EXPORT_TAGS{prio}}, qw(nready));

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
reasons. If performance is not essential you are encouraged to use the
C<Coro::current> function instead.

=cut

$main->{desc} = "[main::]";

# maybe some other module used Coro::Specific before...
$main->{_specific} = $current->{_specific}
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
   require Carp;
   Carp::croak ("FATAL: deadlock detected");
};

sub _cancel {
   my ($self) = @_;

   # free coroutine data and mark as destructed
   $self->_destroy
      or return;

   # call all destruction callbacks
   $_->(@{$self->{_status}})
      for @{(delete $self->{_on_destroy}) || []};
}

# this coroutine is necessary because a coroutine
# cannot destroy itself.
my @destroy;
my $manager;

$manager = new Coro sub {
   while () {
      (shift @destroy)->_cancel
         while @destroy;

      &schedule;
   }
};
$manager->desc ("[coro manager]");
$manager->prio (PRIO_MAX);

# static methods. not really.

=back

=head2 STATIC METHODS

Static methods are actually functions that operate on the current coroutine only.

=over 4

=item async { ... } [@args...]

Create a new asynchronous coroutine and return it's coroutine object
(usually unused). When the sub returns the new coroutine is automatically
terminated.

See the C<Coro::State::new> constructor for info about the coroutine
environment.

Calling C<exit> in a coroutine will do the same as calling exit outside
the coroutine. Likewise, when the coroutine dies, the program will exit,
just as it would in the main program.

   # create a new coroutine that just prints its arguments
   async {
      print "@_\n";
   } 1,2,3,4;

=cut

sub async(&@) {
   my $coro = new Coro @_;
   $coro->ready;
   $coro
}

=item async_pool { ... } [@args...]

Similar to C<async>, but uses a coroutine pool, so you should not call
terminate or join (although you are allowed to), and you get a coroutine
that might have executed other code already (which can be good or bad :).

Also, the block is executed in an C<eval> context and a warning will be
issued in case of an exception instead of terminating the program, as
C<async> does. As the coroutine is being reused, stuff like C<on_destroy>
will not work in the expected way, unless you call terminate or cancel,
which somehow defeats the purpose of pooling.

The priority will be reset to C<0> after each job, tracing will be
disabled, the description will be reset and the default output filehandle
gets restored, so you can change alkl these. Otherwise the coroutine will
be re-used "as-is": most notably if you change other per-coroutine global
stuff such as C<$/> you need to revert that change, which is most simply
done by using local as in C< local $/ >.

The pool size is limited to 8 idle coroutines (this can be adjusted by
changing $Coro::POOL_SIZE), and there can be as many non-idle coros as
required.

If you are concerned about pooled coroutines growing a lot because a
single C<async_pool> used a lot of stackspace you can e.g. C<async_pool
{ terminate }> once per second or so to slowly replenish the pool. In
addition to that, when the stacks used by a handler grows larger than 16kb
(adjustable with $Coro::POOL_RSS) it will also exit.

=cut

our $POOL_SIZE = 8;
our $POOL_RSS  = 16 * 1024;
our @async_pool;

sub pool_handler {
   my $cb;

   while () {
      eval {
         while () {
            _pool_1 $cb;
            &$cb;
            _pool_2 $cb;
            &schedule;
         }
      };

      last if $@ eq "\3terminate\2\n";
      warn $@ if $@;
   }
}

sub async_pool(&@) {
   # this is also inlined into the unlock_scheduler
   my $coro = (pop @async_pool) || new Coro \&pool_handler;

   $coro->{_invoke} = [@_];
   $coro->ready;

   $coro
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

      # call schedule until event occurred.
      # in case we are woken up for other reasons
      # (current still defined), loop.
      Coro::schedule while $current;
   }

=item cede

"Cede" to other coroutines. This function puts the current coroutine into the
ready queue and calls C<schedule>, which has the effect of giving up the
current "timeslice" to other coroutines of the same or higher priority.

Returns true if at least one coroutine switch has happened.

=item Coro::cede_notself

Works like cede, but is not exported by default and will cede to any
coroutine, regardless of priority, once.

Returns true if at least one coroutine switch has happened.

=item terminate [arg...]

Terminates the current coroutine with the given status values (see L<cancel>).

=item killall

Kills/terminates/cancels all coroutines except the currently running
one. This is useful after a fork, either in the child or the parent, as
usually only one of them should inherit the running coroutines.

=cut

sub terminate {
   $current->cancel (@_);
}

sub killall {
   for (Coro::State::list) {
      $_->cancel
         if $_ != $current && UNIVERSAL::isa $_, "Coro";
   }
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

See C<async> and C<Coro::State::new> for additional info about the
coroutine environment.

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
status (default: the empty list). Never returns if the coroutine is the
current coroutine.

=cut

sub cancel {
   my $self = shift;
   $self->{_status} = [@_];

   if ($current == $self) {
      push @destroy, $self;
      $manager->ready;
      &schedule while 1;
   } else {
      $self->_cancel;
   }
}

=item $coroutine->join

Wait until the coroutine terminates and return any values given to the
C<terminate> or C<cancel> functions. C<join> can be called concurrently
from multiple coroutines.

=cut

sub join {
   my $self = shift;

   unless ($self->{_status}) {
      my $current = $current;

      push @{$self->{_on_destroy}}, sub {
         $current->ready;
         undef $current;
      };

      &schedule while $current;
   }

   wantarray ? @{$self->{_status}} : $self->{_status}[0];
}

=item $coroutine->on_destroy (\&cb)

Registers a callback that is called when this coroutine gets destroyed,
but before it is joined. The callback gets passed the terminate arguments,
if any.

=cut

sub on_destroy {
   my ($self, $cb) = @_;

   push @{ $self->{_on_destroy} }, $cb;
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

This method simply sets the C<< $coroutine->{desc} >> member to the given string. You
can modify this member directly if you wish.

=cut

sub desc {
   my $old = $_[0]{desc};
   $_[0]{desc} = $_[1] if @_ > 1;
   $old;
}

=back

=head2 GLOBAL FUNCTIONS

=over 4

=item Coro::nready

Returns the number of coroutines that are currently in the ready state,
i.e. that can be switched to. The value C<0> means that the only runnable
coroutine is the currently running one, so C<cede> would have no effect,
and C<schedule> would cause a deadlock unless there is an idle handler
that wakes up some coroutines.

=item my $guard = Coro::guard { ... }

This creates and returns a guard object. Nothing happens until the object
gets destroyed, in which case the codeblock given as argument will be
executed. This is useful to free locks or other resources in case of a
runtime error or when the coroutine gets canceled, as in both cases the
guard block will be executed. The guard object supports only one method,
C<< ->cancel >>, which will keep the codeblock from being executed.

Example: set some flag and clear it again when the coroutine gets canceled
or the function returns:

   sub do_something {
      my $guard = Coro::guard { $busy = 0 };
      $busy = 1;

      # do something that requires $busy to be true
   }

=cut

sub guard(&) {
   bless \(my $cb = $_[0]), "Coro::guard"
}

sub Coro::guard::cancel {
   ${$_[0]} = sub { };
}

sub Coro::guard::DESTROY {
   ${$_[0]}->();
}


=item unblock_sub { ... }

This utility function takes a BLOCK or code reference and "unblocks" it,
returning the new coderef. This means that the new coderef will return
immediately without blocking, returning nothing, while the original code
ref will be called (with parameters) from within its own coroutine.

The reason this function exists is that many event libraries (such as the
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

our @unblock_queue;

# we create a special coro because we want to cede,
# to reduce pressure on the coro pool (because most callbacks
# return immediately and can be reused) and because we cannot cede
# inside an event callback.
our $unblock_scheduler = new Coro sub {
   while () {
      while (my $cb = pop @unblock_queue) {
         # this is an inlined copy of async_pool
         my $coro = (pop @async_pool) || new Coro \&pool_handler;

         $coro->{_invoke} = $cb;
         $coro->ready;
         cede; # for short-lived callbacks, this reduces pressure on the coro pool
      }
      schedule; # sleep well
   }
};
$unblock_scheduler->desc ("[unblock_sub scheduler]");

sub unblock_sub(&) {
   my $cb = shift;

   sub {
      unshift @unblock_queue, [$cb, @_];
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
   from the same thread (this requirement might be loosened in the future
   to allow per-thread schedulers, but Coro::State does not yet allow
   this).

=head1 SEE ALSO

Support/Utility: L<Coro::Specific>, L<Coro::State>, L<Coro::Util>.

Locking/IPC: L<Coro::Signal>, L<Coro::Channel>, L<Coro::Semaphore>, L<Coro::SemaphoreSet>, L<Coro::RWLock>.

Event/IO: L<Coro::Timer>, L<Coro::Event>, L<Coro::Handle>, L<Coro::Socket>, L<Coro::Select>.

Embedding: L<Coro:MakeMaker>

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

