# a server command shell

use Coro;
use Coro::Handle;
use Coro::Socket;
use Event;

sub shell {
   my $fh = shift;

   while (defined (print $fh "cmd> "), $_ = <$fh>) {
      s/\015?\012$//;
      chomp;
      if (/^q/) {
         Event::unloop;
      } elsif (/^i/) {
         my @data;
         for (values %conn::conn) {
            for (values %$_) {
               next unless $_;
               push @data, "$_->{country}/$_->{remote_addr} $_->{method} $_->{uri}\n";
            }
         }
         print $fh sort @data;
         print $fh scalar@data, " connections\n";#d#
      } elsif (/^ref/) {
         read_blocklist;
      } elsif (/^r/) {
         $::RESTART = 1;
         unloop;
         print $fh "bye bye.\n";
         last;
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
      async \&shell, $port->accept
         while 1;
   };
}

# bind to stdin (debug)
if (1) {
   my $tty;
   open $tty, "+</dev/tty"
      and async \&shell, unblock $tty;
}

