#!/usr/bin/perl

# APNIC refer: KRNIC (for 211.104.0.0)

use Socket;
use Fcntl;

use PApp::SQL;

use Coro;
use Coro::Event;
use Coro::Semaphore;
use Coro::Socket;

$Event::DIED = sub {
   Event::verbose_exception_handler(@_);
   #Event::unloop_all();
};

package Whois;

use PApp::SQL;
use Coro::Event;

sub new {
   my $class = shift;
   my $name = shift;
   my $ip = shift;
   my $self = bless { name => $name, ip => $ip, @_ }, $class;
   $self->{maxjobs} = new Coro::Semaphore $self->{maxjobs} || 1;
   $self;
}

sub ip {
   $_[0]{ip};
}

sub sanitize {
   $_[1];
}

sub whois_request {
   my ($self, $query) = @_;
   my ($id, $whois);

   my $st = sql_exec \($id, $whois),
                     "select id, whois from whois
                      where nic = ? and query = ?",
                     $self->{name}, $query;

   unless ($st->fetch) {
      my $guard = $self->{maxjobs}->guard;
      my $timeout = 5;

      while () {
         my $fh = new Coro::Socket
                         PeerAddr => $self->ip,
                         PeerPort => 'whois',
                         Timeout  => 30;
         if ($fh) {
            print $fh "$query\n";
            $fh->read($whois, 16*1024); # max 16k. whois stored
            close $fh;
            $whois =~ s/\015?\012/\n/g;
            $whois = $self->sanitize($whois);
            if ($whois eq ""
                or ($whois =~ /query limit/i && $whois =~ /exceeded/i) # ARIN
                or ($whois =~ /wait a while and try again/i) # ARIN
                or ($whois =~ /^%ERROR:202:/) # RIPE/APNIC
            ) {
               print "retrying in $timeout seconds\n";#d#
               do_timer(desc => "timer2", after => $timeout);
               $timeout *= 2;
               $timeout = 1 if $timeout > 600;
            } else {
               last;
            }
         }
      }

      sql_exec "replace into whois values (NULL,?,?,NULL,?,?)",
               $self->{name}, $query, $whois, time;

      my $st = sql_exec \$id,
                        "select id from whois
                         where nic = ? and query = ?",
                        $self->{name}, $query;
      $st->fetch or die;
   }

   $whois;
}

package Whois::ARIN;

use Date::Parse;
use PApp::SQL;

use base Whois;

sub sanitize {
   local $_ = $_[1];
   s/\n[\t ]{6,}([0-9.]+ - [0-9.]+)/ $1/g;
   $_;
}

# there are only two problems with arin's whois database:
# a) the data cannot be trusted and often is old or even wrong
# b) the database format is nonparsable
#    (no spaces between netname/ip and netnames can end in digits ;)
# of course, the only source to find out about global
# address distribution is... arin.
sub ip_request {
   my ($self, $ip) = @_;

   my $whois = $self->whois_request($ip);
   
   return () if $whois =~ /^No match/;

   if ($whois =~ /^To single out one record/m) {
      my $handle;
      while ($whois =~ /\G\S.*\(([A-Z0-9\-]+)\).*\n/mg) {
         $handle = $1;
         #return if $handle =~ /-(RIPE|APNIC)/; # heuristic, bbut bad because ripe might not have better info
      }
      $handle or die "$whois ($ip): unparseable multimatch\n";
      $whois = $self->whois_request("!$handle");
   }

   my ($address, $info, $coordinator, undef) = split /\n\n/, $whois;

   $info =~ /^\s+Netname: (\S+)$/mi
      or die "$whois($ip): no netname\n";
   my $netname = $1;

   $info =~ /^\s+Netblock: ([0-9.]+\s+-\s+[0-9.]+)\s*$/mi
      or die "$whois($ip): no netblock\n";
   my $netblock = $1;

   my $maintainer;

   if ($info =~ /^\s+Maintainer: (\S+)\s*$/mi) {
      $maintainer = "*ma: $1\n";
      return if $1 =~ /^(?:AP|RIPE)$/;
   }

   $coordinator =~ s/^\s+Coordinator:\s*//si
      or $coordinator = "";

   $address =~ s/\n\s*(\S+)$//
      or die "$whois($ip): no parseable country ($address)\n";
   my $country = $1;

   $address     =~ s/^\s*/*de: /mg;
   $coordinator =~ s/^\s*/*ad: /mg;

   $whois = <<EOF;
*in: $netblock
*na: $netname
*cy: $country
$maintainer$address
$coordinator
EOF
   $whois =~ s/\n+$//;
   $whois;
}

package Whois::RIPE;

use PApp::SQL;

use base Whois;

sub sanitize {
   local $_ = $_[1];
   s/^%.*\n//gm;
   s/^\n+//;
   s/\n*$/\n/;
   $_;
}

sub ip_request {
   my ($self, $ip) = @_;

   my $whois = $self->whois_request("-FSTin $ip");

   $whois =~ /^\*in: 0\.0\.0\.0 - 255\.255\.255\.255/
      and return;

   $whois =~  /^\*ac: XXX0/m # 192.0.0.0
      and return;

   $whois =~ /^%ERROR:/m
      and return;

   #while ($whois =~ s/^\*(?:ac|tc):\s+(\S+)\n//m) {
   #   $whois .= $self->whois_request("-FSTpn $1");
   #}

   $whois =~ s/^\*(?:pn|nh|mb|ch|so|rz|ny|st|rm):.*\n//mg;

   $whois =~ s/\n+$//;

   $whois;
}

package main;

sub ip2int($) {
   unpack "N", inet_aton $_[0];
}

sub int2ip($) {
   inet_ntoa pack "N", $_[0];
}

our %WHOIS;

$WHOIS{ARIN}  = new Whois::ARIN ARIN  => "whois.arin.net",  maxjobs => 12;
$WHOIS{RIPE}  = new Whois::RIPE RIPE  => "whois.ripe.net",  maxjobs => 20;
$WHOIS{APNIC} = new Whois::RIPE APNIC => "whois.apnic.net", maxjobs => 20;

sub ip_request {
   my $ip = $_[0];
   my $_ip = ip2int($ip);

   my $st = sql_exec \my($whois, $ip0),
                     "select data, ip0 from iprange
                      where ? <= ip1
                      having ip0 <= ?
                      order by ip1
                      limit 1",
                     $_ip, $_ip;

   unless ($st->fetch) {
      my ($arin, $ripe, $apnic);

      $whois = $WHOIS{APNIC}->ip_request($ip)
            || $WHOIS{RIPE} ->ip_request($ip)
            || $WHOIS{ARIN} ->ip_request($ip);

      $whois =~ /^\*in: ([0-9.]+)\s+-\s+([0-9.]+)\s*$/mi
         or do { warn "$whois($ip): no addresses found\n", last };

      my ($ip0, $ip1) = ($1, $2);

      my $_ip0 = ip2int($ip0);
      my $_ip1 = ip2int($ip1);

      if ($_ip0 + 256 < $_ip1) {
         $_ip  = $_ip & 0xffffff00;
         $_ip0 = $_ip       if $_ip0 < $_ip;
         $_ip1 = $_ip + 255 if $_ip1 > $_ip + 255;
      }

      sql_exec "replace into iprange values (?, ?, NULL, ?)",
               $_ip0, $_ip1, $whois;

      #print "$ip ($ip0, $ip1 ($_ip0, $_ip1)\n$whois\n";
   }

   $whois;
}



