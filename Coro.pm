=head1 NAME

Coro - coroutine process abstraction

=head1 SYNOPSIS

 use Coro;

 async {
    # some asynchronous thread of execution
 };

 # alternatively create an async process like this:

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

BEGIN { eval { require warnings } && warnings->unimport ("uninitialized") }

use Coro::State;

use vars qw($idle $main $current);

use base Exporter;

$VERSION = 0.95;

@EXPORT = qw(async cede schedule terminate current);
%EXPORT_TAGS = (
      prio => [qw(PRIO_MAX PRIO_HIGH PRIO_NORMAL PRIO_LOW PRIO_IDLE PRIO_MIN)],
);
@EXPORT_OK = @{$EXPORT_TAGS{prio}};

{
   my @async;
   my $init;

   # this way of handling attributes simply is NOT scalable ;()
   sub import {
      Coro->export_to_level(1, @_);
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

The current coroutine (the last coroutine switched to). The initial value is C<$main> (of course).

=cut

# maybe some other module used Coro::Specific before...
if ($current) {
   $main->{specific} = $current->{specific};
}

$current = $main;

sub current() { $current }

=item $idle

The coroutine to switch to when no other coroutine is running. The default
implementation prints "FATAL: deadlock detected" and exits.

=cut

# should be done using priorities :(
$idle = new Coro sub {
   print STDERR "FATAL: deadlock detected\n";
   exit(51);
};

# this coroutine is necessary because a coroutine
# cannot destroy itself.
my @destroy;
my $manager;
$manager = new Coro sub {
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
         $coro->{_coro_state} = $manager->{_coro_state};
      }
      &schedule;
   }
};

# static methods. not really.

=back

=head2 STATIC METHODS

Static methods are actually functions that operate on the current process only.

=over 4

=item async { ... } [@args...]

Create a new asynchronous process and return it's process object
(usually unused). When the sub returns the new process is automatically
terminated.

   # create a new coroutine that just prints its arguments
   async {
      print "@_\n";
   } 1,2,3,4;

=cut

sub async(&@) {
   my $pid = new Coro @_;
   $manager->ready; # this ensures that the stack is cloned from the manager
   $pid->ready;
   $pid;
}

=item schedule

Calls the scheduler. Please note that the current process will not be put
into the ready queue, so calling this function usually means you will
never be called again.

=cut

=item cede

"Cede" to other processes. This function puts the current process into the
ready queue and calls C<schedule>, which has the effect of giving up the
current "timeslice" to other coroutines of the same or higher priority.

=cut

=item terminate [arg...]

Terminates the current process.

Future versions of this function will allow result arguments.

=cut

sub terminate {
   $current->{status} = [@_];
   $current->cancel;
   &schedule;
   die; # NORETURN
}

=back

# dynamic methods

=head2 PROCESS METHODS

These are the methods you can call on process objects.

=over 4

=item new Coro \&sub [, @args...]

Create a new process and return it. When the sub returns the process
automatically terminates as if C<terminate> with the returned values were
called. To make the process run you must first put it into the ready queue
by calling the ready method.

=cut

sub _newcoro {
   terminate &{+shift};
}

sub new {
   my $class = shift;
   bless {
      _coro_state => (new Coro::State $_[0] && \&_newcoro, @_),
   }, $class;
}

=item $process->ready

Put the given process into the ready queue.

=cut

=item $process->cancel

Like C<terminate>, but terminates the specified process instead.

=cut

sub cancel {
   push @destroy, $_[0];
   $manager->ready;
   &schedule if $current == $_[0];
}

=item $process->join

Wait until the coroutine terminates and return any values given to the
C<terminate> function. C<join> can be called multiple times from multiple
processes.

=cut

sub join {
   my $self = shift;
   unless ($self->{status}) {
      push @{$self->{join}}, $current;
      &schedule;
   }
   wantarray ? @{$self->{status}} : $self->{status}[0];
}

=item $oldprio = $process->prio($newprio)

Sets (or gets, if the argument is missing) the priority of the
process. Higher priority processes get run before lower priority
processes. Priorities are small signed integers (currently -4 .. +3),
that you can refer to using PRIO_xxx constants (use the import tag :prio
to get then):

   PRIO_MAX > PRIO_HIGH > PRIO_NORMAL > PRIO_LOW > PRIO_IDLE > PRIO_MIN
       3    >     1     >      0      >    -1    >    -3     >    -4

   # set priority to HIGH
   current->prio(PRIO_HIGH);

The idle coroutine ($Coro::idle) always has a lower priority than any
existing coroutine.

Changing the priority of the current process will take effect immediately,
but changing the priority of processes in the ready queue (but not
running) will only take effect after the next schedule (of that
process). This is a bug that will be fixed in some future version.

=cut

sub prio {
   my $old = $_[0]{prio};
   $_[0]{prio} = $_[1] if @_ > 1;
   $old;
}

=item $newprio = $process->nice($change)

Similar to C<prio>, but subtract the given value from the priority (i.e.
higher values mean lower priority, just as in unix).

=cut

sub nice {
   $_[0]{prio} -= $_[1];
}

=item $olddesc = $process->desc($newdesc)

Sets (or gets in case the argument is missing) the description for this
process. This is just a free-form string you can associate with a process.

=cut

sub desc {
   my $old = $_[0]{desc};
   $_[0]{desc} = $_[1] if @_ > 1;
   $old;
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

L<Coro::Channel>, L<Coro::Cont>, L<Coro::Specific>, L<Coro::Semaphore>,
L<Coro::Signal>, L<Coro::State>, L<Coro::Timer>, L<Coro::Event>,
L<Coro::L<Coro::RWLock>, Handle>, L<Coro::Socket>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

