=head1 NAME

Coro::State - create and manage simple coroutines

=head1 SYNOPSIS

 use Coro::State;

 $new = new Coro::State sub {
    print "in coroutine (called with @_), switching back\n";
    $new->transfer($main);
    print "in coroutine again, switching back\n";
    $new->transfer($main);
 }, 5;

 $main = new Coro::State;

 print "in main, switching to coroutine\n";
 $main->transfer($new);
 print "back in main, switch to coroutine again\n";
 $main->transfer($new);
 print "back in main\n";

=head1 DESCRIPTION

This module implements coroutines. Coroutines, similar to continuations,
allow you to run more than one "thread of execution" in parallel. Unlike
threads this, only voluntary switching is used so locking problems are
greatly reduced.

This module provides only low-level functionality. See L<Coro> and related
modules for a more useful process abstraction including scheduling.

=over 4

=cut

package Coro::State;

BEGIN {
   $VERSION = 0.09;

   require XSLoader;
   XSLoader::load Coro::State, $VERSION;
}

use base 'Exporter';

@EXPORT_OK = qw(SAVE_DEFAV SAVE_DEFSV SAVE_ERRSV);

=item $coro = new [$coderef] [, @args...]

Create a new coroutine and return it. The first C<transfer> call to this
coroutine will start execution at the given coderef. If, the subroutine
returns it will be executed again.

The coderef you submit MUST NOT be a closure that refers to variables
in an outer scope. This does NOT work.

If the coderef is omitted this function will create a new "empty"
coroutine, i.e. a coroutine that cannot be transfered to but can be used
to save the current coroutine in.

=cut

sub _newcoro {
   my $proc = shift;
   do {
      eval { &$proc };
      if ($@) {
         my $err = $@;
         $error->(undef, $err);
         print STDERR "FATAL: error function returned\n";
         exit(50);
      }
   } while (1);
}

sub new {
   my $class = shift;
   my $proc = shift || sub { die "tried to transfer to an empty coroutine" };
   bless _newprocess [$proc, @_], $class;
}

=item $prev->transfer($next,[$flags])

Save the state of the current subroutine in C<$prev> and switch to the
coroutine saved in C<$next>.

The "state" of a subroutine includes the scope, i.e. lexical variables and
the current execution state. The C<$flags> value can be used to specify
that additional state be saved/restored, by C<||>-ing the following
constants together:

   Constant            Effect
   SAVE_DEFAV          save/restore @_
   SAVE_DEFSV          save/restore $_
   SAVE_ERRSV          save/restore $@

These constants are not exported by default. The default is subject to
change (because we are still at an early development stage) but will
stabilize. You have to make sure that the destination state is valid with
respect to the flags, segfaults or worse will result otherwise.

If you feel that something important is missing then tell me.  Also
remember that every function call that might call C<transfer> (such
as C<Coro::Channel::put>) might clobber any global and/or special
variables. Yes, this is by design ;) You can always create your own
process abstraction model that saves these variables.

The easiest way to do this is to create your own scheduling primitive like this:

  sub schedule {
     local ($_, $@, ...);
     $old->transfer($new);
  }

IMPLEMENTORS NOTE: all Coro::State functions/methods expect either the
usual Coro::State object or a hashref with a key named "_coro_state" that
contains the real Coro::State object. That is, you can do:

  $obj->{_coro_state} = new Coro::State ...;
  Coro::State::transfer(..., $obj);

This exists mainly to ease subclassing (wether through @ISA or not).

=cut

=item $error->($error_coro, $error_msg)

This function will be called on fatal errors. C<$error_msg> and
C<$error_coro> return the error message and the error-causing coroutine
(NOT an object) respectively. This API might change.

=cut

$error = sub {
   require Carp;
   Carp::confess("FATAL: $_[1]\n");
};

=item Coro::State::flush

To be efficient (actually, to not be abysmaly slow), this module does
some fair amount of caching (a possibly complex structure for every
subroutine in use). If you don't use coroutines anymore or you want to
reclaim some memory then you can call this function which will flush all
internal caches. The caches will be rebuilt when needed so this is a safe
operation.

=cut

1;

=back

=head1 BUGS

This module has not yet been extensively tested. Expect segfaults and
specially memleaks.

This module is not thread-safe. You must only ever use this module from
the same thread (this requirenmnt might be loosened in the future).

=head1 SEE ALSO

L<Coro>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

