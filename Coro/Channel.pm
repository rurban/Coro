=head1 NAME

Coro::Channel - message queues

=head1 SYNOPSIS

 use Coro::Channel;

 $q1 = new Coro::Channel <maxsize>;

 $q1->put("xxx");
 print $q1->get;

 die unless $q1->size;

=head1 DESCRIPTION

=over 4

=cut

package Coro::Channel;

use Coro ();

$VERSION = 0.08;

=item $q = new Coro:Channel $maxsize

Create a new channel with the given maximum size (unlimited if C<maxsize>
is omitted). Stating a size of zero gives you a traditional channel, i.e.
a queue that can store only a single element.

=cut

sub new {
   # [\@contents, $queue, $maxsize];
   bless [[], [], $_[1]], $_[0];
}

=item $q->put($scalar)

Put the given scalar into the queue.

=cut

sub put {
   push @{$_[0][0]}, $_[1];
   (pop @{$_[0][1]})->ready if @{$_[0][1]};
   &Coro::yield if defined $_[0][2] && @{$_[0][0]} > $_[0][2];
}

=item $q->get

Return the next element from the queue, waiting if necessary.

=cut

sub get {
   while (!@{$_[0][0]}) {
      push @{$_[0][1]}, $Coro::current;
      &Coro::schedule;
   }
   shift @{$_[0][0]};
}

=item $q->size

Return the number of elements waiting to be consumed. Please note that:

  if ($q->size) {
     my $data = $q->get;
  }

is NOT a race condition but works fine.

=cut

sub size {
   scalar @{$_[0][0]};
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

