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
Threads but don't run in parallel.

This module is still experimental, see the BUGS section below.

In this module, coroutines are defined as "callchain + lexical variables
+ @_ + $_ + $@ + $^W + C stack), that is, a coroutine has it's own
callchain, it's own set of lexicals and it's own set of perl's most
important global variables.

=cut

package Coro;

use Coro::State;

use base Exporter;

$VERSION = 0.10;

@EXPORT = qw(async cede schedule terminate current);
@EXPORT_OK = qw($current);

{
   my @async;

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
            } else {
               push @attrs, $_;
            }
         }
         return $old ? $old->($package, $ref, @attrs) : @attrs;
      };
   }

   sub INIT {
      &async(pop @async) while @async;
   }
}

=item $main

This coroutine represents the main program.

=cut

our $main = new Coro;

=item $current (or as function: current)

The current coroutine (the last coroutine switched to). The initial value is C<$main> (of course).

=cut

# maybe some other module used Coro::Specific before...
if ($current) {
   $main->{specific} = $current->{specific};
}

our $current = $main;

sub current() { $current }

=item $idle

The coroutine to switch to when no other coroutine is running. The default
implementation prints "FATAL: deadlock detected" and exits.

=cut

# should be done using priorities :(
our $idle = new Coro sub {
   print STDERR "FATAL: deadlock detected\n";
   exit(51);
};

# we really need priorities...
my @ready; # the ready queue. hehe, rather broken ;)

# static methods. not really.

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

The coderef you submit MUST NOT be a closure that refers to variables
in an outer scope. This does NOT work. Pass arguments into it instead.

=cut

sub async(&@) {
   my $pid = new Coro @_;
   $pid->ready;
   $pid;
}

=item schedule

Calls the scheduler. Please note that the current process will not be put
into the ready queue, so calling this function usually means you will
never be called again.

=cut

my $prev;

sub schedule {
   # should be done using priorities :(
   ($prev, $current) = ($current, shift @ready || $idle);
   Coro::State::transfer($prev, $current);
}

=item cede

"Cede" to other processes. This function puts the current process into the
ready queue and calls C<schedule>, which has the effect of giving up the
current "timeslice" to other coroutines of the same or higher priority.

=cut

sub cede {
   $current->ready;
   &schedule;
}

=item terminate

Terminates the current process.

Future versions of this function will allow result arguments.

=cut

# this coroutine is necessary because a coroutine
# cannot destroy itself.
my @destroy;
my $terminate = new Coro sub {
   while() {
      delete ((pop @destroy)->{_coro_state}) while @destroy;
      &schedule;
   }
};

sub terminate {
   push @destroy, $current;
   $terminate->ready;
   &schedule;
   # NORETURN
}

=back

# dynamic methods

=head2 PROCESS METHODS

These are the methods you can call on process objects.

=over 4

=item new Coro \&sub [, @args...]

Create a new process and return it. When the sub returns the process
automatically terminates. To start the process you must first put it into
the ready queue by calling the ready method.

The coderef you submit MUST NOT be a closure that refers to variables
in an outer scope. This does NOT work. Pass arguments into it instead.

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

Put the current process into the ready queue.

=cut

sub ready {
   push @ready, $_[0];
}

=back

=cut

1;

=head1 BUGS/LIMITATIONS

 - could be faster, especially when the core would introduce special
   support for coroutines (like it does for threads).
 - there is still a memleak on coroutine termination that I could not
   identify. Could be as small as a single SV.
 - this module is not well-tested.
 - if variables or arguments "disappear" (become undef) or become
   corrupted please contact the author so he cen iron out the
   remaining bugs.
 - this module is not thread-safe. You must only ever use this module from
   the same thread (this requirement might be loosened in the future to
   allow per-thread schedulers, but Coro::State does not yet allow this).

=head1 SEE ALSO

L<Coro::Channel>, L<Coro::Cont>, L<Coro::Specific>, L<Coro::Semaphore>,
L<Coro::Signal>, L<Coro::State>, L<Coro::Event>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

