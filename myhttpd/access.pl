
our @blockuri;
our @blockref;

sub read_blockuri {
   local *B;
   my %group;
   @blockuri = ();
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
            push @blockuri, [qr/$g/i, \@r];
         } elsif (/\S/) {
            print "blockuri: unparsable line: $_\n";
         }
      }
   } else {
      print "no blockuri\n";
   }
}

sub read_blockref {
   local *B;
   @blockref = ();
   if (open B, "<blockreferer") {
      while (<B>) {
         chomp;
         if (/^([^\t]*)\t\s*(.*)/) {
            push @blockref, qr/^$1/i;
         } elsif (/\S/) {
            print "blockref: unparsable line: $_\n";
         }
      }
   } else {
      print "no blockref\n";
   }
}

read_blockuri;
read_blockref;

use Tie::Cache;
tie %whois_cache, Tie::Cache::, $MAX_CONNECTS * 1.5;

sub conn::err_block_country {
   my $self = shift;
   my $whois = shift;

   $whois =~ s/&/&amp;/g;
   $whois =~ s/</&lt;/g;
   $self->err(403, "forbidden", { "Content-Type" => "text/html", Connection => "close" }, <<EOF);
<html>
<head>
<title>This material is licensed in your country!</title>
</head>
<body bgcolor="#ffffff" text="#000000" link="#0000ff" vlink="#000080" alink="#ff0000">

<h1>This material is licensed in your country!</h1>

<p>My research has shown that your IP address
(<b>$self->{remote_addr}</b>) most probably is located in this country:
<b>$self->{country}</b> (ISO-3166-2 code, XX == unknown). The full record is:</p>

<pre>
$whois
</pre>

<p>My database says that the material you are trying to access is licensed
in your country. If I would distribute these files to your country I would
actively <em>hurt</em> the industry behind it, which includes the artists
and authors of these videos/mangas. So I hope you understand that I try to
avoid this.</p>

<p>Please see the <a href="http://www.goof.com/pcg/marc/animefaq.html#licensed">FAQ</a>
for a more thorough explanation.</p>

<p>If you <em>really</em> think that this is wrong, i.e. the
material you tried to access is <em>not</em> licensed in your
country or your ip address was misdetected, you can write to <a
href="mailto:licensed\@plan9.de">licensed\@plan9.de</a>. Please explain
what happened and why you think this is wrong in as much detail as
possible.</p>

<div align="right">Thanks a lot for understanding.</div>

</body>
</html>
EOF
}

sub conn::err_block_referer {
   my $self = shift;

   my $uri = $self->{uri};
   $uri =~ s/\/[^\/]+$/\//;

   $self->slog(6, "REFERER($self->{uri},$self->{h}{referer})");

   $whois =~ s/&/&amp;/g;
   $whois =~ s/</&lt;/g;
   $self->err(203, "non-authoritative", { "Content-Type" => "text/html" }, <<EOF);
<html>
<head>
<title>Unallowed Referral</title>
</head>
<body bgcolor="#ffffff" text="#000000" link="#0000ff" vlink="#000080" alink="#ff0000">

<h1>The site which referred you has done something bad!</h1>

<p>It seems that you are coming from this URL:</p>

<pre>$self->{h}{referer}</pre>

<p>This site has been blocked, either because it required you to pay
money, forced you to click on banners, claimed these files were theirs
or something very similar. Please note that you can download these files
<em>without</em> having to pay, <em>without</em> clicking banners or jump
through other hoops.</p>

<p><b>Sites like the one you came from actively hurt the distribution of
these files and the service quality for you since I can't move or correct
files and you will likely not be able to see the full archive.</b></p>

<p>Having that this, you can find the original content (if it is still
there) by <b>following <a href="$uri">this link</a>.</b></p>

<div align="right">Thanks a lot for understanding.</div>

</body>
</html>
EOF
}

sub conn::access_check {
   my $self = shift;

   my $ref = $self->{h}{referer};
   my $uri = $self->{path};
   my %disallow;

   for (@blockref) {
      $self->err_block_referer if $ref =~ $_;
   }

   for (@blockuri) {
      if ($uri =~ $_->[0]) {
         $disallow{$_}++ for @{$_->[1]};
      }
   }
   
   my $whois = $whois_cache{$self->{remote_addr}}
               ||= ::ip_request($self->{remote_addr});

   my $country = "XX";

   if ($whois =~ /^\*cy: (\S+)/m) {
      $country = uc $1;
   } else {
      $self->slog(9, "no country($whois)");
   }

   $self->{country} = $country;

   if ($disallow{$country}) {
      $self->err_block_country($whois);
   }
}

1;
