
our @blocklist;

sub read_blocklist {
   local *B;
   my %group;
   @blocklist = ();
   if (open B, "<blocklist") {
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
            push @blocklist, [qr/$g/i, \@r];
         } elsif (/\S/) {
            print "blocklist: unparsable line: $_\n";
         }
      }
   } else {
      print "no blocklst\n";
   }
}

read_blocklist;

sub conn::access_check {
   my $self = shift;

   my $uri = $self->{path};
   my %disallow;

   for (@blocklist) {
      if ($uri =~ $_->[0]) {
         $disallow{$_}++ for @{$_->[1]};
      }
   }
   
   my $whois = ::ip_request($self->{remote_addr});

   my $country = "XX";

   if ($whois =~ /^\*cy: (\S+)/m) {
      $country = uc $1;
   } else {
      $self->slog(9, "no country($whois)");
   }

   if ($disallow{$country}) {
      $whois =~ s/&/&amp;/g;
      $whois =~ s/</&lt;/g;
      $self->err(403, "forbidden", { "Content-Type" => "text/html" }, <<EOF);
<html>
<head>
<title>This material is licensed in your country!</title>
</head>
<body bgcolor="#ffffff" text="#000000" link="#0000ff" vlink="#000080" alink="#ff0000">

<h1>This material is licensed in your country!</h1>

<p>My research has shown that your IP address
(<b>$self->{remote_addr}</b>) most probably is located in this country:
<b>$country</b> (ISO-3166-2 code, XX == unknown). The full record is:</p>

<pre>
$whois
</pre>

<p>My database says that the material you are trying to access is licensed
in your country. If I would distribute these files to your country I would
actively <em>hurt</em> the industry behind it, which includes the artists
and authors of these videos/mangas. So I hope you understand that I try to
avoid this.</p>

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
}

1;
