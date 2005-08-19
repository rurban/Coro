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
C<transfer> will perl stacks (a few k) and optionally C stack (4-16k) be
allocated. On systems supporting mmap a 128k stack is allocated, on the
assumption that the OS has on-demand virtual memory. All this is very
system-dependent. On my i686-pc-linux-gnu system this amounts to about 10k
per coroutine, 5k when the experimental context sharing is enabled.

=head2 FUNCTIONS

=over 4

=cut

package Coro::State;

BEGIN { eval { require warnings } && warnings->unimport ("uninitialized") }

BEGIN {
   $VERSION = 1.3;

   require DynaLoader;
   push @ISA, 'DynaLoader';
   bootstrap Coro::State $VERSION;
}

use base 'Exporter';

@EXPORT_OK = qw(SAVE_DEFAV SAVE_DEFSV SAVE_ERRSV SAVE_CURPM SAVE_CCTXT);

=item $coro = new [$coderef] [, @args...]

Create a new coroutine and return it. The first C<transfer> call to this
coroutine will start execution at the given coderef. If the subroutine
returns it will be executed again.

If the coderef is omitted this function will create a new "empty"
coroutine, i.e. a coroutine that cannot be transfered to but can be used
to save the current coroutine in.

=cut

# this is called (or rather: goto'ed) for each and every
# new coroutine. IT MUST NEVER RETURN!
sub initialize {
   my $proc = shift;
   eval {
      &$proc while 1;
   };
   if ($@) {
      print STDERR "FATAL: uncaught exception\n$@";
   }
   _exit 255;
}

sub new {
   my $class = shift;
   my $proc = shift || sub { die "tried to transfer to an empty coroutine" };
   bless _newprocess [$proc, @_], $class;
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
   SAVE_CCTXT  save/restore C-stack (you usually want this for coroutines)

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

IMPLEMENTORS NOTE: all Coro::State functions/methods expect either the
usual Coro::State object or a hashref with a key named "_coro_state" that
contains the real Coro::State object. That is, you can do:

  $obj->{_coro_state} = new Coro::State ...;
  Coro::State::transfer (..., $obj);

This exists mainly to ease subclassing (wether through @ISA or not).

=cut

1;

=back

=head1 BUGS

This module has not yet been extensively tested, but works on most
platforms. Expect segfaults and memleaks (but please don't be surprised if
it works...)

This module is not thread-safe. You must only ever use this module from
the same thread (this requirement might be loosened in the future).

=head1 SEE ALSO

L<Coro>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

