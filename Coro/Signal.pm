=head1 NAME

Coro::Signal - coroutine signals (binary semaphores)

=head1 SYNOPSIS

 use Coro::Signal;

 $sig = new Coro::Signal;

 $sig->wait; # wait for signal

 # ... some other "thread"

 $sig->send;

=head1 DESCRIPTION

=over 4

=cut

package Coro::Signal;

use Coro::Process ();

$VERSION = 0.01;

sub new {
   bless [], $_[0];
}

sub wait {
   my $self = shift;
   if ($self->[0]) {
      $self->[0] = 0;
   } else {
      push @{$self->[1]}, $Coro::current;
      Coro::Process::schedule;
   }
}

sub send {
   my $self = shift;
   if (@{$self->[1]}) {
      (shift @{$self->[1]})->ready;
   } else {
      $self->[0] = 1;
   }
}

sub awaited {
   !!@{$self->[1]};
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

