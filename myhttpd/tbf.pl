package tbf;

# kind of token-bucket-filter

my $max_per_client = 1e5;

sub new {
   my $class = shift;
   my %arg = @_;
   my $self = bless \%arg, $class;

   $self->{maxbucket} ||= $self->{rate} * 3; # max 3s bucket
   $self->{minbucket} ||= $self->{rate}; # minimum bucket to share
   $self->{interval}  ||= $::BUFSIZE / $max_per_client; # good default interval

   if ($self->{rate}) {
      $self->{w} = Event->timer(hard => 1, after => 0, interval => $self->{interval}, repeat => 1, cb => sub {
         $self->inject($self->{rate} * $self->{interval});
      });
   } else {
      die "chaining not yet implemented\n";
   }

   $self;
}

sub DESTROY {
   my $self = shift;

   $self->{w}->cancel;
}

sub inject {
   my ($self, $bytes) = @_;

   $self->{bucket} += $bytes;

   while ($self->{bucket} >= $self->{minbucket}) {
      if ($self->{waitw}) {
         my $rate = $self->{bucket} / $self->{waitw};

         for my $v (values %{$self->{waitq}}) {
            $self->{bucket} -= $rate * $v->[0];
            $v->[1]         += $rate * $v->[0];

            if ($v->[1] >= $v->[2]) {
               $self->{bucket} += $v->[1] - $v->[2];
               $v->[3]->();
            }
         }

      } else {
         if ($self->{maxbucket} < $self->{bucket}) {
            ::unused_bandwidth ($self->{bucket} - $self->{maxbucket});
            $self->{bucket} = $self->{maxbucket};
         }
      }

      last;
   }
}

my $_tbf_id;

sub request {
   my ($self, $bytes, $weight) = @_;

   $weight ||= 1;

   my $coro = $Coro::current;
   my $id   = $_tbf_id++;

   $self->{waitw} += $weight;
   $self->{waitq}{$id} = [$weight, 0, $bytes, sub {
      delete $self->{waitq}{$id};
      $self->{waitw} -= $weight;
      $coro->ready;
   }];

   Coro::schedule;
}

1;
