package transferqueue;

use Scalar::Util;

my @reserve = (
      [  1_200_000, 1],
      [  8_000_000, 1],
      [ 75_000_000, 1],
);

sub new {
   my $class = shift;
   my $self = bless {
      slots   => $_[0],
      lastspb => 0,
      avgspb  => 0,
   }, $class;
   $self->{reschedule} = Event->timer(
         after => 10,
         interval => 3,
         cb => sub { $self->wake_next },
   );
   $self;
}

sub start_transfer {
   my $self = shift;
   my $size = $_[0];

   my $transfer = bless {
      queue   => $self,
      time    => $::NOW,
      size    => $size,
      coro    => $Coro::current,
      started => 0,
   }, transfer::;

   push @{$self->{wait}}, $transfer;

   $self->wake_next;

   $transfer;
}

sub sort {
   my @queue = grep $_, @{$_[0]{wait}};

   $_->{spb} = ($::NOW-$_->{time}) / ($_->{size} || 1) for @queue;
   
   $_[0]{wait} = [sort { $b->{spb} <=> $a->{spb} } @queue];

   Scalar::Util::weaken $_ for @{$_[0]{wait}};
}

sub wake_next {
   my $self = shift;

   $self->sort;

   while (@{$self->{wait}}) {
      my $size = $self->{wait}[0]{size};
      my $min = 0;
      for (@reserve) {
         last if $size <= $_->[0];
         $min += $_->[1];
      }
      last unless $self->{slots} > $min;
      my $transfer = shift @{$self->{wait}};
      $self->{lastspb} = $transfer->{spb};
      $self->{avgspb} = $self->{avgspb} * 0.99 + $transfer->{spb} * 0.01;
      $self->{started}++;
      $transfer->wake;
      last;
   }
}

sub force_wake_next {
   my $self = shift;

   $self->{slots} += 1;
   $self->wake_next;
   $self->{slots} -= 1;
}

sub waiters {
   $_[0]->sort;
   @{$_[0]{wait}};
}

sub DESTROY {
   my $self = shift;

   $self->{reschedule}->cancel;
}

package transfer;

use Coro::Timer ();

sub wake {
   my $self = shift;

   $self->{alloc} = 1;
   $self->{queue}{slots}--;
   $self->{wake} and $self->{wake}->ready;
}

sub try {
   my $self = shift;

   $self->{alloc} || do {
      my $timeout = Coro::Timer::timeout $_[0];
      local $self->{wake} = $self->{coro};

      Coro::schedule;

      $self->{alloc};
   }
}

sub DESTROY {
   my $self = shift;

   if ($self->{alloc}) {
      $self->{queue}{slots}++;
      $self->{queue}->wake_next;
   }
}

1;

