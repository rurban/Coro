# a server command shell

use Coro;
use Coro::Handle;
use Coro::Socket;
use Event;
use Time::HiRes 'time';

my $last_ts = time;

sub shell {
   my $fh = shift;

   while (defined (print $fh "cmd> "), $_ = <$fh>) {
      s/\015?\012$//;
      chomp;
      if (/^q/) {
         Event::unloop;
      } elsif (/^i/) {
         $::NOW = time+1e-6;
         my @data;
         for (values %conn::conn) {
            for (values %$_) {
               next unless $_;
               my $rate = sprintf "%.1f", $_->{written} / ($::NOW - $_->{time});
               push @data, "$_->{country}/$_->{remote_addr} $_->{written} $rate $_->{method} $_->{uri}\n";
            }
         }
         print $fh sort @data;
         print $fh scalar@data, " ($::conns) connections\n";#d#
         print $fh "$::written bytes written in the last ",$::NOW - $last_ts, " seconds\n";
         printf $fh "(%.1f bytes/s)\n", $::written / ($::NOW - $last_ts);
         ($last_ts, $::written) = ($::NOW, 0);
      } elsif (/^ref/) {
         read_blocklist;
      } elsif (/^r/) {
         $::RESTART = 1;
         unloop;
         print $fh "bye bye.\n";
         last;
      } elsif (/^co\S*\s+(\S+)/) {
         print $fh ip_request($1), "\n";
      } else {
         print $fh "try quit, info, restart, refresh\n";
      }
   }
}

# bind to tcp port
if ($CMDSHELL_PORT) {
   my $port = new Coro::Socket
        LocalAddr => "127.0.0.1",
        LocalPort => $CMDSHELL_PORT,
        ReuseAddr => 1,
        Listen => 1,
   or die "unable to bind cmdshell port: $!";

   push @listen_sockets, $port;

   async {
      while () {
         async \&shell, scalar $port->accept;
      }
   };
}

# bind to stdin (debug)
if (1) {
   my $tty;
   open $tty, "+</dev/tty"
      and async \&shell, unblock $tty;
}

