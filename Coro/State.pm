=head1 NAME

Coro::State - create and manage simple coroutines

=head1 SYNOPSIS

 use Coro::State;

 $new = new Coro::State sub {
    print "in coroutine (called with @_), switching back\n";
    $new->transfer ($main);
    print "in coroutine again, switching back\n";
    $new->transfer ($main);
 }, 5;

 $main = new Coro::State;

 print "in main, switching to coroutine\n";
 $main->transfer ($new);
 print "back in main, switch to coroutine again\n";
 $main->transfer ($new);
 print "back in main\n";

=head1 DESCRIPTION

This module implements coroutines. Coroutines, similar to continuations,
allow you to run more than one "thread of execution" in parallel. Unlike
threads, there is no parallelism and only voluntary switching is used so
locking problems are greatly reduced.

This can be used to implement non-local jumps, exception handling,
continuations and more.

This module provides only low-level functionality. See L<Coro> and related
modules for a higher level process abstraction including scheduling.

=head2 MEMORY CONSUMPTION

A newly created coroutine that has not been used only allocates a
relatively small (a few hundred bytes) structure. Only on the first
C<transfer> will perl stacks (a few k) and optionally C stack. All this
is very system-dependent. On my x86_64-pc-linux-gnu system this amounts
to about 8k per (non-trivial) coroutine.

=head2 FUNCTIONS

=over 4

=cut

package Coro::State;

use strict;
no warnings "uninitialized";

use XSLoader;

BEGIN {
   our $VERSION = '3.0';

   # must be done here because the xs part expects it to exist
   # it might exist already because Coro::Specific created it.
   $Coro::current ||= { };

   XSLoader::load __PACKAGE__, $VERSION;
}

use Exporter;
use base Exporter::;

our @EXPORT_OK = qw(SAVE_DEFAV SAVE_DEFSV SAVE_ERRSV SAVE_IRSSV SAVE_ALL);

=item $coro = new Coro::State [$coderef[, @args...]]

Create a new coroutine and return it. The first C<transfer> call to this
coroutine will start execution at the given coderef. If the subroutine
returns it will be executed again. If it throws an exception the program
will terminate.

The initial save flags for a new state is C<SAVE_ALL>, which can be
changed using the C<save> method.

Calling C<exit> in a coroutine will not work correctly, so do not do that.

If the coderef is omitted this function will create a new "empty"
coroutine, i.e. a coroutine that cannot be transfered to but can be used
to save the current coroutine in.

The returned object is an empty hash which can be used for any purpose
whatsoever, for example when subclassing Coro::State.

=cut

# this is called for each newly created C coroutine,
# and is being artificially injected into the opcode flow.
# its sole purpose is to call transfer() once so it knows
# the stop level stack frame for stack sharing.
sub _cctx_init {
   _set_stacklevel $_[0];
}

# this is called (or rather: goto'ed) for each and every
# new coroutine. IT MUST NEVER RETURN!
sub _coro_init {
   eval {
      my $coro = shift;
      $coro or die "transfer() to empty coroutine $coro";
      &$coro;
   };
   print STDERR $@ || "FATAL: Coro::State callback returned unexpectedly, exiting.\n";
   _exit 254;
}

=item $old_save_flags = $state->save ([$new_save_flags])

It is possible to "localise" certain global variables for each state:
for example, it would be awkward if @_ or $_ would suddenly change just
because you temporarily switched to another coroutine, so Coro::State can
save those variables in the state object on transfers.

The C<$new_save_flags> value can be used to specify which variables (and
other things) are to be saved (and later restored) on each transfer, by
ORing the following constants together:

   Constant    Effect
   SAVE_DEFAV  save/restore @_
   SAVE_DEFSV  save/restore $_
   SAVE_ERRSV  save/restore $@
   SAVE_IRSSV  save/restore $/ (the Input Record Separator, slow)
   SAVE_ALL    everything that can be saved

These constants are not exported by default. If you don't need any extra
additional variables saved, use C<0> as the flags value.

If you feel that something important is missing then tell me. Also
remember that every function call that might call C<transfer> (such
as C<Coro::Channel::put>) might clobber any global and/or special
variables. Yes, this is by design ;) You can always create your own
process abstraction model that saves these variables.

The easiest way to do this is to create your own scheduling primitive like
this:

  sub schedule {
     local ($_, $@, ...);
     $old->transfer ($new);
  }

=item $prev->transfer ($next)

Save the state of the current subroutine in C<$prev> and switch to the
coroutine saved in C<$next>.

The "state" of a subroutine includes the scope, i.e. lexical variables and
the current execution state (subroutine, stack).

=item Coro::State::cctx_count

Returns the number of C-level coroutines allocated. If this number is
very high (more than a dozen) it might help to identify points of C-level
recursion in your code and moving this into a separate coroutine.

=item Coro::State::cctx_idle

Returns the number of allocated but idle (free for reuse) C level
coroutines. As C level coroutines are curretly rarely being deallocated, a
high number means that you used many C coroutines in the past.

=cut

1;

=back

=head1 BUGS

This module is not thread-safe. You must only ever use this module from
the same thread (this requirement might be loosened in the future).

=head1 SEE ALSO

L<Coro>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

