=head1 NAME

Coro::Semaphore - non-binary semaphores

=head1 SYNOPSIS

 use Coro::Semaphore;

 $sig = new Coro::Semaphore [initial value];

 $sig->down; # wait for signal

 # ... some other "thread"

 $sig->up;

=head1 DESCRIPTION

This module implements counted semaphores. You can initialize a mutex
with any level of parallel users, that is, you can intialize a sempahore
that can be C<down>ed more than once until it blocks. There is no owner
associated with semaphores, so one coroutine can C<down> it while another
can C<up> it.

Counting semaphores are typically used to coordinate access to
resources, with the semaphore count initialized to the number of free
resources. Coroutines then increment the count when resources are added
and decrement the count when resources are removed.

=over 4

=cut

package Coro::Semaphore;

use Coro ();

$VERSION = 0.13;

=item new [inital count, default one]

Creates a new sempahore object with the given initial lock count. The
default lock count is 1, which means it is unlocked by default. Zero (or
negative values) are also allowed, in which case the semaphore is locked
by default.

=cut

sub new {
   bless [defined $_[1] ? $_[1] : 1], $_[0];
}

=item $sem->down

Decrement the counter, therefore "locking" the semaphore. This method
waits until the semaphore is available if the counter is zero.

=cut

sub down {
   my $self = shift;
   while ($self->[0] <= 0) {
      push @{$self->[1]}, $Coro::current;
      Coro::schedule;
   }
   --$self->[0];
}

=item $sem->up

Unlock the semaphore again.

=cut

sub up {
   my $self = shift;
   if (++$self->[0] > 0) {
      (shift @{$self->[1]})->ready if @{$self->[1]};
   }
}

=item $sem->try

Try to C<down> the semaphore. Returns true when this was possible,
otherwise return false and leave the semaphore unchanged.

=cut

sub try {
   my $self = shift;
   if ($self->[0] > 0) {
      --$self->[0];
      return 1;
   } else {
      return 0;
   }
}

=item $guard = $sem->guard

This method calls C<down> and then creates a guard object. When the guard
object is destroyed it automatically calls C<up>.

=cut

sub guard {
   $_[0]->down;
   # double indirection because bless works on the referenced
   # object, not (only) on the reference itself.
   bless \\$_[0], Coro::Semaphore::Guard::;
}

sub Coro::Semaphore::Guard::DESTROY {
   ${${$_[0]}}->up;
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

