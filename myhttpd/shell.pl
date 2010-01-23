# a server command shell

use EV;
use Coro;
use Coro::EV;
use Coro::Handle;
use Coro::Socket;
use Time::HiRes 'time';

use Text::Abbrev;

my $last_ts = time;

my %complete;
my @commands = qw(quit squit refresh country clrwhois restart block info print clrdiridx);

abbrev \%complete, @commands;

sub shell {
   my $fh = shift;

   while (defined (print $fh "cmd> "), $_ = $fh->readline) {
      s/\015?\012$//;
      if (s/^(\S+)\s*// && (my $cmd = $complete{$1})) {
         if ($cmd eq "quit") {
            print $fh "bye bye.\n";#d#
            last;
         } elsif ($cmd eq "squit") {
            print $fh "server quit.\n";#d#
            EV::unloop;
            last;
         } elsif ($cmd eq "print") {
            my @res = eval $_;
            print $fh "eval: $@\n" if $@;
            print $fh "RES = ", (join " : ", @res), "\n";
         } elsif ($cmd eq "block") {
            print "blocked '$_'\n";#d#
            $conn::blocked{$_} = [time + $::BLOCKTIME, "blocked by operator"];
         } elsif ($cmd eq "info") {
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
            print $fh "$::written bytes written in the last ", $::NOW - $last_ts, " seconds\n";
            printf $fh "(%.1f bytes/s)\n", $::written / ($::NOW - $last_ts);
            ($last_ts, $::written) = ($::NOW, 0);
         } elsif ($cmd eq "refresh") {
            do "config.pl";
            print $fh "config.pl: $@\n" if $@;
            %statdata_cache = ();
            conn::read_blockuri;
            conn::read_blockref;
         } elsif ($cmd eq "clrdiridx") {
            %statdata_cache = ();
            delete $diridx{$_} for keys %diridx; # server error on %diridx = ();
         } elsif ($cmd eq "restart") {
            $::RESTART = 1;
            EV::unloop;
            print $fh "restarting, cu!\n";
            last;
         } elsif ($cmd eq "country") {
            print $fh netgeo::ip_request($_), "\n";
         } elsif ($cmd eq "clrwhois") {
            netgeo::clear_cache;
         }
      } else {
         print $fh "try one of @commands\n";
      }
   }
}

# bind to tcp port
if ($CMDSHELL_PORT) {
   my $port = new Coro::Socket
        #LocalAddr => "127.0.0.1",
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

