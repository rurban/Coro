package transferqueue;

sub new {
   my $class = shift;
   bless {
      slots   => $_[0],
      lastspb => 0,
   }, $class;
}

sub start_transfer {
   my $self = shift;
   my $size = $_[0];

   my $trans = bless {
      queue => $self,
      time  => $::NOW,
      size  => $size,
      coro  => $Coro::current,
   }, transfer::;

   push @{$self->{wait}}, $trans;
   Scalar::Util::weaken($self->{wait}[-1]);

   $self->wake_next;

   $trans;
}

sub wake_next {
   my $self = shift;

   $self->sort;

   while($self->{slots} && @{$self->{wait}}) {
      my $transfer = shift @{$self->{wait}};
      if ($transfer) {
         $self->{lastspb} = $transfer->{spb};
         $transfer->wake;
         last;
      }
   }
}

sub sort {
   $_[0]{wait} = [
      sort { $b->{spb} <=> $a->{spb} }
         grep { $_ && ($_->{spb} = ($::NOW-$_->{time})/($_->{size}||1)), $_ }
            @{$_[0]{wait}}
   ];
}

sub waiters {
   $_[0]->sort;
   @{$_[0]{wait}};
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
