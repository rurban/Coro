=head1 NAME

Coro::Semaphore - non-binary semaphores

=head1 SYNOPSIS

 use Coro::Semaphore;

 $sig = new Coro::Semaphore [init];

 $sig->down; # wait for signal

 # ... some other "thread"

 $sig->up;

=head1 DESCRIPTION

=over 4

=cut

package Coro::Semaphore;

use Coro::Process ();

$VERSION = 0.01;

sub new {
   bless [defined $_[1] ? $_[1] : 1], $_[0];
}

sub down {
   my $self = shift;
   while ($self->[0] <= 0) {
      push @{$self->[1]}, $Coro::current;
      Coro::Process::schedule;
   }
   --$self->[0];
}

sub up {
   my $self = shift;
   if (++$self->[0] > 0) {
      (shift @{$self->[1]})->ready if @{$self->[1]};
   }
}

sub try {
   my $self = shift;
   if ($self->[0] > 0) {
      --$self->[0];
      return 1;
   } else {
      return 0;
   }
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

