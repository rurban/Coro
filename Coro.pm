=head1 NAME

Coro - create an manage coroutines

=head1 SYNOPSIS

 use Coro;

=head1 DESCRIPTION

=over 4

=cut

package Coro;

BEGIN {
   $VERSION = 0.01;

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
   print STDERR "FATAL: $error_msg, program aborted\n";
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
      } while ();
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

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

