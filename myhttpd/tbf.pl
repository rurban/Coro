package tbf;

# kind of token-bucket-filter

our $max_per_client = $::TBF_MAX_PER_CLIENT || 118000;

sub new {
   my $class = shift;
   my %arg = @_;
   my $self = bless \%arg, $class;

   $self->{maxbucket} ||= $::TBF_MAX_BUCKET || $self->{rate} * 5; # max bucket
   $self->{minbucket} ||= $self->{rate}; # minimum bucket to share
   $self->{interval}  ||= $::BUFSIZE / $max_per_client; # good default interval

   if ($self->{rate}) {
      $self->{w} = EV::periodic 0, $self->{interval}, undef, sub {
         $self->inject ($self->{rate} * $self->{interval});
      };
   } else {
      die "chaining not yet implemented\n";
   }

   $self;
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

      }
      last;
   }

   if ($self->{maxbucket} < $self->{bucket}) {
      ::unused_bandwidth ($self->{bucket} - $self->{maxbucket});
      $self->{bucket} = $self->{maxbucket};
   }
}

my $_tbf_id;

sub request {
   my ($self, $bytes, $weight) = @_;

   $weight ||= 1;

   my $id = $_tbf_id++;
   my $cb = Coro::rouse_cb;

   $self->{waitw} += $weight;
   $self->{waitq}{$id} = [$weight, 0, $bytes, sub {
      delete $self->{waitq}{$id};
      $self->{waitw} -= $weight;
      &$cb;
   }];

   Coro::rouse_wait;
}

1;
