sub statuspage {
   my ($self, $verbose) = @_;

   my $uptime = format_time ($::NOW - $::starttime);
   
   my $content = <<EOF;
<html>
<head><title>Server Status Page</title></head>
<body bgcolor="#ffffff" text="#000000" link="#0000ff" vlink="#000080" alink="#ff0000">
<h1>Server Status Page</h1>
<h2>Myhttpd</h2>
version <b>$VERSION</b>; current:max connection count: <b>$::conns</b>:<b>$::maxconns</b>; uptime: <b>$uptime</b>;<br />
client-id <b>$self->{remote_id}</b>; client country <b>$self->{country}</b>;<br />
<h2>Queue Statistics</h2>
<ul>
EOF

   for (
         ["download queue", $queue_file],
         $verbose ? (["other queue",    $queue_index])
                  : (),
   ) {
      my ($name, $queue) = @$_;
      my @waiters = $queue->waiters;
      $waiters[$_]{idx} = $_ + 1 for 0..$#waiters;

      if (@waiters) {
         $content .= "<li>$name<br />".(scalar @waiters)." client(s); $queue->{started} downloads started; $queue->{slots} slots free;";
         
         $content .= "<p>Waiting time until download starts, estimated:<ul>";
         for (
               ["by queue average", $queue->{avgspb}],
               $verbose ? (["by most recently started transfer", $queue->{lastspb}],
                           ["by next client in queue", $waiters[0]{spb}])
                        : (),
         ) {
            my ($by, $spb) = @$_;
            $content .= "<li>$by<br />";
            if ($spb) {
               $content .= sprintf "100 KB file: <b>%s</b>; 1 MB file: <b>%s</b>; 100MB file: <b>%s</b>;",
                                   format_time($spb*    100_000),
                                   format_time($spb*  1_000_000),
                                   format_time($spb*100_000_000);
            } else {
               $content .= "(unavailable)";
            }
            $content .= "</li>";
         }
         $content .= "</ul></p>";

         @waiters = grep { $verbose || $_->{coro}{conn}{remote_id} eq $self->{remote_id} } @waiters;
         if (@waiters) {
            $content .= "<table border='1' width='100%'><tr><th>#</th><th>CN</th>".
                        "<th>Remote ID</th><th>Size</th><th>Waiting</th><th>ETA</th><th>URI</th></tr>";
            for (@waiters) {
               my $conn = $_->{coro}{conn};
               my $time = format_time ($::NOW - $_->{time});
               my $eta  = $queue->{avgspb} * $_->{size} - ($::NOW - $_->{time});

               $content .= "<tr>".
                           "<td align='right'>$_->{idx}</td>".
                           "<td>$conn->{country}</td>".
                           "<td>$conn->{remote_id}</td>".
                           "<td align='right'>$_->{size}</td>".
                           "<td align='right'>$time</td>".
                           "<td align='right'>".($eta < 0 ? "<font color='red'>overdue</font>" : format_time $eta)."</td>".
                           "<td>".escape_html($conn->{name})."</td>".
                           "</tr>";
            }
            $content .= "</table></li>";
         }
         $content .= "</li>";
      } else {
         $content .= "<li>$name<br />(empty)</li>";
      }
   }

   $content .= <<EOF;
</ul>
<h2>Active Connections</h2>
<ul>
EOF

   my @data;
   my $count = 0;
   my $fullrate = 0;

   for (values %conn::conn) {
      for (values %$_) {
         next unless $_;
         $count++;
         my $rate = sprintf "%.1f", $_->{written} / (($::NOW - $_->{time}) || 1e999);
         $fullrate += $rate;

         next unless $verbose || $_->{remote_id} eq $self->{remote_id};
         
         push @data, "<tr><td>$_->{country}</td><td>$_->{remote_id}</td><td align='right'>$_->{written}</td><td align='right'>$rate</td><td>$_->{method}</td><td>$_->{uri}</td></tr>";
      }
   }

   if (@data) {
      $content .= "<table width='100%' border='1'><tr><th>CN</th><th>Remote ID</th><th>bytes written</th><th>bps</th><th>RM</th><th>URI</th></tr>"
                . (join "", sort @data)
                . "</table>";
   }

   $content .= "<p>$count active downloads, $fullrate bytes/s amortized.</p>";

   $content .= <<EOF;
</ul>
</body>
</html>
EOF

   $self->response(200, "ok",
         {
            "Content-Type"   => "text/html",
            "Content-Length" => length $content,
         },
         $content);
};

$::internal{status} = sub { statuspage($_[0], 0) };
$::internal{queue}  = sub { statuspage($_[0], 1) };

1;

