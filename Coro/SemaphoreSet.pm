=head1 NAME

Coro::SemaphoreSet - hash of semaphores.

=head1 SYNOPSIS

 use Coro::SemaphoreSet;

 $sig = new Coro::SemaphoreSet [initial value];

 $sig->down("semaphoreid"); # wait for signal

 # ... some other "thread"

 $sig->up("semaphoreid");

=head1 DESCRIPTION

This module implements sets of counting semaphores (see
L<Coro::Semaphore>). It is nothing more than a hash with normal semaphores
as members, but is more efficiently managed.

This is useful if you want to allow parallel tasks to run in parallel but
not on the same problem. Just use a SemaphoreSet and lock on the problem
identifier.

=over 4

=cut

package Coro::SemaphoreSet;

no warnings qw(uninitialized);

use Coro ();

$VERSION = 0.51;

=item new [inital count]

Creates a new sempahore set with the given initial lock count for each
individual semaphore. See L<Coro::Semaphore>.

=cut

sub new {
   bless [defined $_[1] ? $_[1] : 1], $_[0];
}

=item $sem->down($id)

Decrement the counter, therefore "locking" the named semaphore. This
method waits until the semaphore is available if the counter is zero.

=cut

sub down {
   my $sem = ($_[0][1]{$_[1]} ||= [$_[0][0]]);
   while ($sem->[0] <= 0) {
      push @{$sem->[1]}, $Coro::current;
      Coro::schedule;
   }
   --$sem->[0];
}

=item $sem->up($id)

Unlock the semaphore again.

=cut

sub up {
   my $sem = $_[0][1]{$_[1]};
   if (++$sem->[0] > 0) {
      (shift @{$sem->[1]})->ready if @{$sem->[1]};
   }
   delete $_[0][1]{$_[1]} if $sem->[0] == $_[0][0];
}

=item $sem->try

Try to C<down> the semaphore. Returns true when this was possible,
otherwise return false and leave the semaphore unchanged.

=cut

sub try {
   my $sem = ($_[0][1]{$_[1]} ||= [$_[0][0]]);
   if ($sem->[0] > 0) {
      --$sem->[0];
      return 1;
   } else {
      return 0;
   }
}

=item $sem->waiters($id)

In scalar context, returns the number of coroutines waiting for this
semaphore.

=cut

sub waiters {
   @{$_[0][1]{$_[1]}};
}

=item $guard = $sem->guard($id)

This method calls C<down> and then creates a guard object. When the guard
object is destroyed it automatically calls C<up>.

=cut

sub guard {
   &down;
   # double indirection because bless works on the referenced
   # object, not (only) on the reference itself.
   bless [@_], Coro::SemaphoreSet::Guard::;
}

sub Coro::SemaphoreSet::Guard::DESTROY {
   &up(@{$_[0]});
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

