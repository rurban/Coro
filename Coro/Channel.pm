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

use Coro::Process ();

$VERSION = 0.01;

sub new {
   # [\@contents, $queue, $maxsize];
   bless [[], [], $_[1]], $_[0];
}

sub put {
   push @{$_[0][0]}, $_[1];
   (pop @{$_[0][1]})->ready if @{$_[0][1]};
   &Coro::Process::yield if defined $_[0][2] && @{$_[0][0]} > $_[0][2];
}

sub get {
   while (!@{$_[0][0]}) {
      push @{$_[0][1]}, $Coro::current;
      &Coro::Process::schedule;
   }
   shift @{$_[0][0]};
}

sub size {
   scalar @{$_[0][0]};
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

