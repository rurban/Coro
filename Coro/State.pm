=head1 NAME

Coro::State - create and manage simple coroutines

=head1 SYNOPSIS

 use Coro::State;

 $new = new Coro::State sub {
    print "in coroutine, switching back\n";
    $new->transfer($main);
    print "in coroutine again, switching back\n";
    $new->transfer($main);
 };

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
   $VERSION = 0.03;

   require XSLoader;
   XSLoader::load Coro::State, $VERSION;
}

=item $coro = new [$coderef [, @args]]

Create a new coroutine and return it. The first C<transfer> call to this
coroutine will start execution at the given coderef. If, the subroutine
returns it will be executed again.

If the coderef is omitted this function will create a new "empty"
coroutine, i.e. a coroutine that cannot be transfered to but can be used
to save the current coroutine in.

=cut

sub new {
   my $class = $_[0];
   my $proc = $_[1] || sub { die "tried to transfer to an empty coroutine" };
   bless newprocess {
      do {
         eval { &$proc };
         if ($@) {
            $error->(undef, $@);
            print STDERR "FATAL: error function returned\n";
            exit(50);
         }
      } while (1);
   }, $class;
}

=item $prev->transfer($next)

Save the state of the current subroutine in C<$prev> and switch to the
coroutine saved in C<$next>.

The "state" of a subroutine only ever includes scope, i.e. lexical
variables and the current execution state. It does not save/restore any
global variables such as C<$_> or C<$@> or any other special or non
special variables. So remember that every function call that might call
C<transfer> (such as C<Coro::Channel::put>) might clobber any global
and/or special variables. Yes, this is by design ;) You cna always create
your own process abstraction model that saves these variables.

The easiest way to do this is to create your own scheduling primitive like this:

  sub schedule {
     local ($_, $@, ...);
     $old->transfer($new);
  }

=cut

=item $error->($error_coro, $error_msg)

This function will be called on fatal errors. C<$error_msg> and
C<$error_coro> return the error message and the error-causing coroutine
(NOT an object) respectively. This API might change.

=cut

$error = sub {
   require Carp;
   Carp::confess("FATAL: $_[1]\nprogram aborted\n");
};

1;

=back

=head1 BUGS

This module has not yet been extensively tested. Expect segfaults and
specially memleaks.

=head1 SEE ALSO

L<Coro>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

