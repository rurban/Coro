=head1 NAME

Coro::RWLock - reader/write locks

=head1 SYNOPSIS

 use Coro::RWLock;

 $lck = new Coro::RWLock;

 $lck->rdlock; # acquire read lock

 $lck->unlock;

=head1 DESCRIPTION

This module implements reader/write locks. A read can be acquired for
read by many coroutines in parallel as long as no writer has locked it
(shared access). A single write lock can be acquired when no readers
exist. RWLocks basically allow many concurrent readers (without writers)
OR a single writer (but no readers).

=over 4

=cut

package Coro::RWLock;

use Coro ();

$VERSION = 0.12;

die "NYI";

=item $l = new Coro::RWLock;

Create a new reader/writer lock.

=cut

sub new {
   # [wrcount, rdcount, [readqueue], [waitqueue]]
   bless [0, 0, [], []], $_[0];
}

=item $l->rdlock

Acquire a read lock.

=item $l->tryrdlock

Try to acquire a read lock.

=cut

sub rdlock {
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

