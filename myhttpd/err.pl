use HTTP::Date;

use Coro::EV;

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

sub conn::err_blocked {
   my $self = shift;
   my $id = $self->{remote_id};
   my $block = $conn::blocked{$id};

   $block->[2]++;
   
   if ($block->[0] < $::NOW + $::BLOCKTIME) {
      $block->[0] = $::NOW + $::BLOCKTIME;
   }

   my $status = 403;
   my $hdr = {
      "Content-Type" => "text/html",
      "Retry-After" => $block->[0] - $::NOW,
      "Connection" => "close",
   };

   my $ctime = $HTTP_NOW;
   my $etime = time2str $block->[0];

   my $limit = $block->[3];
   $block->[3] = $::NOW + 10;

   if ($limit > $::NOW) {
      Coro::EV::timer_once $limit - $::NOW;

      if ($block->[2] > 20) {
         $block->[3] = $::NOW + $::DYNABLOCK + 360;
         $status = 401;
         $hdr->{Warning} = "Please do NOT retry, your IP has been blocked due to excessive hammering. Press Cancel instead.";
         $hdr->{"WWW-Authenticate"} = "Basic realm=\"Please do NOT retry, you IP has been blocked due to excessive hammering. Press Cancel instead.\"";

         if ($block->[2] > 40) {
            system "/root/s/dynablock --dur $::DYNABLOCK --add $self->{remote_addr} &";
         }
      }
   }

   $self->err($status, $block->[1], $hdr,
              <<EOF);
<html>
<head>
<title>$block->[1]</title>
</head>
<body bgcolor="#ffffff" text="#000000" link="#0000ff" vlink="#000080" alink="#ff0000">

<p>You have been blocked because you didn't behave. The exact reason was:</p>

   <h1><blockquote>"$block->[1]"</blockquote></h1>

<p>You may retry not earlier than:</p>

   <p><blockquote>$etime.</blockquote></p>

<p>Until then, each access will renew the block.</p>

<p>For your reference, the current time and your connection ID is:</p>
   
   <p><blockquote>$ctime | $id</blockquote></p>
   
</body></html>
EOF
}

sub conn::err_segmented_download {
   my $self = shift;
   $self->err(400, "segmented downloads are not allowed",
              { "Content-Type" => "text/html", Connection => "close" }, <<EOF);
<html>
<head>
<title>Segmented downloads are not allowed</title>
</head>
<body bgcolor="#ffffff" text="#000000" link="#0000ff" vlink="#000080" alink="#ff0000">

<p>Segmented downloads are not allowed on this server.</p>

</body></html>
EOF
}

1;

