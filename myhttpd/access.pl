package transferqueue;

my @reserve = (
      [  1_200_000, 1],
      [  3_000_000, 1],
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
      $self->{avgspb} ||= $transfer->{spb};
      $self->{avgspb} = $self->{avgspb} * 0.95 + $transfer->{spb} * 0.05;
      $self->{started}++;
      $transfer->wake;
      last;
   }
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

package conn;

our %blockuri;
our $blockref;

sub read_blockuri {
   local *B;
   my %group;
   %blockuri = ();
   if (open B, "<blockuri") {
      while (<B>) {
         chomp;
         if (/^group\s+(\S+)\s+(.*)/i) {
            $group{$1} = [split /\s+/, $2];
         } elsif (/^!([^\t]*)\t\s*(.*)/) {
            my $g = $1;
            my @r;
            for (split /\s+/, $2) {
               push @r, $group{$_} ? @{$group{$_}} : $_;
            }
            print "not($g) => (@r)\n";
            push @{$blockuri{$_}}, $g for @r;
            push @blockuri, [qr/$g/i, \@r];
         } elsif (/\S/) {
            print "blockuri: unparsable line: $_\n";
         }
      }
      for (keys %blockuri) {
         my $qr = join ")|(?:", @{$blockuri{$_}};
         $blockuri{$_} = qr{(?:$qr)}i;
      }
   } else {
      print "no blockuri\n";
   }
}

sub read_blockref {
   local *B;
   my @blockref;
   if (open B, "<blockreferer") {
      while (<B>) {
         chomp;
         if (/^([^\t]*)\t\s*(.*)/) {
            push @blockref, $1;
         } elsif (/\S/) {
            print "blockref: unparsable line: $_\n";
         }
      }
      $blockref = join ")|(?:", @blockref;
      $blockref = qr{^(?:$blockref)}i;
   } else {
      print "no blockref\n";
      $blockref = qr{^x^};
   }
}

read_blockuri;
read_blockref;

use Tie::Cache;
tie %whois_cache, Tie::Cache::, 32;

sub access_check {
   my $self = shift;

   my $ref = $self->{h}{referer};
   my $uri = $self->{path};
   my %disallow;

   $self->err_block_referer
      if $self->{h}{referer} =~ $blockref;

   my $whois = $whois_cache{$self->{remote_addr}}
               ||= netgeo::ip_request($self->{remote_addr});

   my $country = "XX";

   if ($whois =~ /^\*cy: (\S+)/m) {
      $country = uc $1;
   } else {
      $self->slog(9, "no country($whois)");
   }

   $self->{country} = $country;

   $self->err_block_country($whois)
      if $self->{path} =~ $blockuri{$country};
}

1;
