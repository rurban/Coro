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
use Coro::Specific;

use base 'Exporter';

$VERSION = 0.07;
@EXPORT = qw(cont result);

=item cont { ... }

Create a new "continuation" (well, almost, you cannot return from it).

=cut

our $curr = new Coro::Specific;
our @result;

sub cont(&) {
   my $code = $_[0];
   my $coro = new Coro::State sub { &$code while 1 };
   my $prev = new Coro::State;
   sub {
      push @$$curr, [$coro, $prev];
      $prev->transfer($coro);
      wantarray ? @{pop @result} : ${pop @result}[0];
   };
}

=item result [list]

Return the given list/scalar as result of the continuation.

=cut

sub result {
   push @result, [@_];
   &Coro::State::transfer(@{pop @$$curr});
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

