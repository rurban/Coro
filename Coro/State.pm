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
C<transfer> will perl stacks (a few k) and optionally C stack All this
is very system-dependent. On my i686-pc-linux-gnu system this amounts
to about 10k per coroutine, 5k when the experimental context sharing is
enabled.

=head2 FUNCTIONS

=over 4

=cut

package Coro::State;

use strict;
no warnings "uninitialized";

use XSLoader;

BEGIN {
   our $VERSION = '3.0';

   XSLoader::load __PACKAGE__, $VERSION;
}

use Exporter;
use base Exporter::;

our @EXPORT_OK = qw(SAVE_DEFAV SAVE_DEFSV SAVE_ERRSV);

=item $coro = new Coro::State [$coderef[, @args...]]

Create a new coroutine and return it. The first C<transfer> call to this
coroutine will start execution at the given coderef. If the subroutine
returns it will be executed again. If it throws an exception the program
will terminate.

Calling C<exit> in a coroutine will not work correctly, so do not do that.

If the coderef is omitted this function will create a new "empty"
coroutine, i.e. a coroutine that cannot be transfered to but can be used
to save the current coroutine in.

The returned object is an empty hash which can be used for any purpose
whatsoever, for example when subclassing Coro::State.

=cut

our $_cctx; # holds the coro_cctx pointer

# this is called for each newly created C coroutine,
# and is being artificially injected into the opcode flow
sub _cctx_init {
   _set_stacklevel $_cctx;
}

# this is called (or rather: goto'ed) for each and every
# new coroutine. IT MUST NEVER RETURN!
sub _coro_init {
   eval {
      $_[0] or die "transfer() to empty coroutine $_[0]";
      &{$_[0]} while 1;
   };
   print STDERR $@ if $@;
   _exit 55;
}

=item $prev->transfer ($next, $flags)

Save the state of the current subroutine in C<$prev> and switch to the
coroutine saved in C<$next>.

The "state" of a subroutine includes the scope, i.e. lexical variables and
the current execution state (subroutine, stack). The C<$flags> value can
be used to specify that additional state to be saved (and later restored), by
oring the following constants together:

   Constant    Effect
   SAVE_DEFAV  save/restore @_
   SAVE_DEFSV  save/restore $_
   SAVE_ERRSV  save/restore $@

These constants are not exported by default. If you don't need any extra
additional state saved, use C<0> as the flags value.

If you feel that something important is missing then tell me.  Also
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

