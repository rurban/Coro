use HTTP::Date;

use Coro::Event;

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

sub conn::err_blocked {
   my $self = shift;
   my $ip = $self->{remote_addr};
   my $ctime = $HTTP_NOW;
   my $etime = time2str $conn::blocked{$ip} = $::NOW + $::BLOCKTIME;

   Coro::Event::do_timer(after => 20*rand);

   $self->err(401, "too many connections",
              {
                 "Content-Type" => "text/html",
                 "Retry-After" => $::BLOCKTIME,
                 "Warning" => "Please do NOT retry, you have been blocked. Press Cancel instead.",
                 "WWW-Authenticate" => "Basic realm=\"Please do NOT retry, you have been blocked. Press Cancel instead.\"",
                 "Connection" => "close",
              },
              <<EOF);
<html>
<head>
<title>Too many connections</title>
</head>
<body bgcolor="#ffffff" text="#000000" link="#0000ff" vlink="#000080" alink="#ff0000">

<p>You have been blocked because you opened too many connections. You
may retry at</p>

   <p><blockquote>$etime.</blockquote></p>

<p>For your reference, the current time is:</p>
   
   <p><blockquote>$ctime.</blockquote></p>
   
<p>Until then, each new access will renew the block. You might want to have a
look at the <a href="http://www.goof.com/pcg/marc/animefaq.html#blocked">FAQ</a>.</p>

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

<p>Segmented downloads are not allowed on this server. Please refer to the
<a href="http://www.goof.com/pcg/marc/animefaq.html#segmented_downloads">FAQ</a>.</p>

</body></html>
EOF
}

1;

