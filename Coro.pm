=head1 NAME

Coro - create and manage simple coroutines

=head1 SYNOPSIS

 use Coro;

 $new = new Coro sub {
    print "in coroutine, switching back\n";
    $new->transfer($main);
    print "in coroutine again, switching back\n";
    $new->transfer($main);
 };

 $main = new Coro;

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

Although this is the "main" module of the Coro family it provides only
low-level functionality. See L<Coro::Process> and related modules for a
more useful process abstraction including scheduling.

=over 4

=cut

package Coro;

BEGIN {
   $VERSION = 0.03;

   require XSLoader;
   XSLoader::load Coro, $VERSION;
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
   bless _newprocess {
      do {
         eval { &$proc };
         if ($@) {
            $error_msg  = $@;
            $error_coro = _newprocess { };
            &transfer($error_coro, $error);
         }
      } while (1);
   }, $class;
}

=item $prev->transfer($next)

Save the state of the current subroutine in $prev and switch to the
coroutine saved in $next.

=cut

# I call the _transfer function from a perl function
# because that way perl saves all important things on
# the stack.
sub transfer {
   _transfer($_[0], $_[1]);
}

=item $error, $error_msg, $error_coro

This coroutine will be called on fatal errors. C<$error_msg> and
C<$error_coro> return the error message and the error-causing coroutine
(NOT an object) respectively. This API might change.

=cut

$error_msg =
$error_coro = undef;

$error = _newprocess {
   print STDERR "FATAL: $error_msg\nprogram aborted\n";
   exit 50;
};

1;

=back

=head1 BUGS

This module has not yet been extensively tested.

=head1 SEE ALSO

L<Coro::Process>, L<Coro::Signal>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

