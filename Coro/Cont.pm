=head1 NAME

Coro::Cont - continuations in perl

=head1 SYNOPSIS

 use Coro::Cont;

 # multiply all hash keys by 2
 my $cont = csub {
    yield $_*2;
    yield $_;
 };
 my %hash2 = map &$cont, %hash1;

 # dasselbe in grün (as the germans say)
 sub mul2 : Cont {
    yield $_[0]*2;
    yield $_[0];
 }

 my %hash2 = map mul2($_), %hash1;

=head1 DESCRIPTION

=over 4

=cut

package Coro::Cont;

BEGIN { eval { require warnings } && warnings->unimport }

use Carp qw(croak);

use Coro::State;

use vars qw($return);

use base 'Exporter';

$VERSION = 1.51;
@EXPORT = qw(csub yield);

{
   my @csub;

   # this way of handling attributes simply is NOT scalable ;()
   sub import {
      Coro::Cont->export_to_level(1, @_);
      my $old = *{(caller)[0]."::MODIFY_CODE_ATTRIBUTES"}{CODE};
      *{(caller)[0]."::MODIFY_CODE_ATTRIBUTES"} = sub {
         my ($package, $ref) = (shift, shift);
         my @attrs;
         for (@_) {
            if ($_ eq "Cont") {
               push @csub, [$package, $ref];
            } else {
               push @attrs, $_;
            }
         }
         return $old ? $old->($package, $ref, @attrs) : @attrs;
      };
   }

   sub findsym {
      my ($pkg, $ref) = @_;
      my $type = ref $ref;
      for my $sym (values %{$pkg."::"}) {
         return \$sym if *{$sym}{$type} == $ref;
      }
      ();
   }

   sub INIT {
      # prototypes are currently being ignored
      for (@csub) {
         my $ref = findsym(@$_)
            or croak "package $package: cannot declare non-global subs as 'Cont'";
         *$ref = &csub($_->[1]);
      }
      @csub = ();
   }
}

=item csub { ... }

Create a new "continuation" (when the sub falls of the end it is being
terminated).

=cut

sub csub(&) {
   my $code = $_[0];
   my $prev = new Coro::State;

   my $coro = new Coro::State sub {
      # we do this superfluous switch just to
      # avoid the parameter passing problem
      # on the first call
      &yield;
      &$code while 1;
   };

   # call it once
   push @{ $Coro::current->{yieldstack} }, [$coro, $prev];
   &Coro::State::transfer($prev, $coro, 0);

   sub {
      push @{ $Coro::current->{yieldstack} }, [$coro, $prev];
      &Coro::State::transfer($prev, $coro, 0);
      wantarray ? @_ : $_[0];
   };
}

=item @_ = yield [list]

Return the given list/scalar as result of the continuation. Also returns
the new arguments given to the subroutine on the next call.

=cut

# implemented in Coro/State.xs
#sub yield(@) {
#   &Coro::State::transfer(@{pop @$$return}, 0);
#   wantarray ? @_ : $_[0];
#}

1;

=back

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

