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
tie %whois_cache, Tie::Cache::, $::MAX_CONNECTS * 1.5;

sub access_check {
   my $self = shift;

   my $ref = $self->{h}{referer};
   my $uri = $self->{path};
   my %disallow;

   $self->err_block_referer
      if $self->{h}{referer} =~ $blockref;

   my $whois = $whois_cache{$self->{remote_addr}}
               ||= ::ip_request($self->{remote_addr});

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
