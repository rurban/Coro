=head1 NAME

Coro::Cont - schmorp's faked continuations

=head1 SYNOPSIS

 use Coro::Cont;

 # multiply all hash keys by 2
 my $cont = cont {
    result $_*2;
    result $_;
 };
 my %hash2 = map &$cont, &hash1;


=head1 DESCRIPTION

=over 4

=cut

package Coro::Cont;

use Coro::State;

use base 'Exporter';

$VERSION = 0.01;
@EXPORT = qw(cont result);

=item cont { ... }

Create a new "continuation" (well, almost, you cannot return from it).

=cut

our $prev = new Coro::State;
our $cont;
our $result;

sub cont(&) {
   my $code = $_[0];
   my $coro = new Coro::State sub {
      &$code while 1;
   };
   sub {
      local $cont = $coro;
      local $result;
      $prev->transfer($cont);
      @$result;
   };
}

=item result [list]

Return the given list/scalar as result of the continuation.

=cut

sub result {
   $result = [@_];
   $cont->transfer($prev);
}

1;

=back

=head1 BUGS

This module does not yet work in the presence of coroutines (see
L<Coro>). The reason for this is that there is no defined way to
save/restore globals on task-switches. Implementing Coro::Cont using
Coro would fix this, but is rather overkilled ;)

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

