# a server command shell

use Coro;
use Coro::Handle;
use Coro::Socket;
use Event;

sub shell {
   my $fh = shift;

   while (defined (print $fh "cmd> "), $_ = <$fh>) {
      chomp;
      if (/quit/) {
         Event::unloop;
      } elsif (/info/) {
         my @conn;
         push @conn, values %$_ for values %conn::conn;
         for (values %conn::conn) {
            for (values %$_) {
               next unless $_;
               print "$_: $_->{remote_addr} $_->{uri}\n";
            }
         }
      } else {
         print "try quit\n";
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

   async {
      async \&shell, $port->accept;
   };
}

# bind to stdin (debug)
if (1) {
   my $tty;
   open $tty, "+</dev/tty"
      and async \&shell, unblock $tty;
}

