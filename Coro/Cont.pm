=head1 NAME

Coro::Cont - schmorp's faked continuations

=head1 SYNOPSIS

 use Coro::Cont;

 # multiply all hash keys by 2
 my $cont = csub {
    result $_*2;
    result $_;
 };
 my %hash2 = map &$csub, &hash1;

 # dasselbe in grün (as we germans say)
 sub mul2 : Cont {
    result $_*2;
    result $_;
 }

 my %hash2 = map mul2, &hash1;


=head1 DESCRIPTION

=over 4

=cut

package Coro::Cont;

use Coro::State;
use Coro::Specific;

use base 'Exporter';

$VERSION = 0.08;
@EXPORT = qw(csub result);

{
   use subs 'csub';

   my @csub;

   # this way of handling attributes simply is NOT scalable ;()
   sub import {
      Coro::Cont->export_to_level(1, @_);
      my $old = *{(caller)[0]."::MODIFY_CODE_ATTRIBUTES"}{CODE};
      no warnings;
      *{(caller)[0]."::MODIFY_CODE_ATTRIBUTES"} = sub {
         my ($package, $ref) = (shift, shift);
         my @attrs;
         for (@_) {
            if ($_ eq "Cont") {
               push @csub, $ref;
            } else {
               push @attrs, $_;
            }
         }
         return $old ? $old->($package, $ref, @attrs) : @attrs;
      };
   }

   sub INIT {
      for (@csub) {
         $$_ = csub $$_;
      }
      @csub = ();
   }
}

=item csub { ... }

Create a new "continuation" (when the sub falls of the end it is being
terminated).

=cut

our $curr = new Coro::Specific;
our @result;

sub csub(&) {
   my $code = $_[0];
   my $coro = new Coro::State sub { &$code while 1 };
   my $prev = new Coro::State;
   sub {
      push @$$curr, [$coro, $prev];
      &Coro::State::transfer($prev, $coro, 0);
      wantarray ? @{pop @result} : ${pop @result}[0];
   };
}

=item result [list]

Return the given list/scalar as result of the continuation.

=cut

sub result {
   push @result, [@_];
   &Coro::State::transfer(@{pop @$$curr}, 0);
   @_;
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

