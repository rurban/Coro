=head1 NAME

Coro - create and manage coroutines

=head1 SYNOPSIS

 use Coro;

 $new = new Coro sub {
    print "in coroutine, switching back\n";
    $Coro::main->resume;
    print "in coroutine again, switching back\n";
    $Coro::main->resume;
 };

 print "in main, switching to coroutine\n";
 $new->resume;
 print "back in main, switch to coroutine again\n";
 $new->resume;
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
   $VERSION = 0.02;

   require XSLoader;
   XSLoader::load Coro, $VERSION;
}

=item $main

This coroutine represents the main program.

=item $current

The current coroutine (the last coroutine switched to). The initial value is C<$main> (of course).

=cut

$main = $current = _newprocess { 
   # never being called
};

=item $error, $error_msg, $error_coro

This coroutine will be called on fatal errors. C<$error_msg> and
C<$error_coro> return the error message and the error-causing coroutine,
respectively.

=cut

$error_msg =
$error_coro = undef;

$error = _newprocess {
   print STDERR "FATAL: $error_msg\nprogram aborted\n";
   exit 250;
};

=item $coro = new $coderef [, @args]

Create a new coroutine and return it. The first C<resume> call to this
coroutine will start execution at the given coderef. If it returns it
should return a coroutine to switch to. If, after returning, the coroutine
is C<resume>d again it starts execution again at the givne coderef.

=cut

sub new {
   my $class = $_[0];
   my $proc = $_[1];
   bless _newprocess {
      do {
         eval { &$proc->resume };
         if ($@) {
            ($error_msg, $error_coro) = ($@, $current);
            $error->resume;
         }
      } while (1);
   }, $class;
}

=item $coro->resume

Resume execution at the given coroutine.

=cut

my $prev;

sub resume {
   $prev = $current; $current = $_[0];
   _transfer($prev, $current);
}

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

