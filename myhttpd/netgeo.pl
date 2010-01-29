#!/usr/bin/perl

# APNIC refer: KRNIC (for 211.104.0.0)

use Socket;
use Fcntl;

use Coro;
use Coro::EV;
use Coro::Semaphore;
use Coro::SemaphoreSet;
use Coro::Socket;
use Coro::Timer;

use BerkeleyDB;

tie %netgeo::whois, BerkeleyDB::Btree,
    -Env => $db_env,
    -Filename => "whois",
    -Flags => DB_CREATE,
       or die "unable to create/open whois table";
$netgeo::iprange = new BerkeleyDB::Btree
    -Env => $db_env,
    -Filename => "iprange",
    -Flags => DB_CREATE,
       or die "unable to create/open iprange table";

package Whois;

use Coro::EV;

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

   my $id = "$self->{name}\x0$query";
   my $whois = $netgeo::whois{$id};

   unless (defined $whois) {
      print "WHOIS($self->{name},$query)\n";

      my $guard = $self->{maxjobs}->guard;
      my $timeout = 5;

      while () {
         my $fh = new Coro::Socket
                         PeerAddr => $self->ip,
                         PeerPort => $self->{port} || "whois",
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
         } else {
            # only retry once a minute
            print STDERR "unable to connect to $self->{ip} ($self->{name}), retrying...\n";
            Coro::Timer::sleep 300;
         }
      }

      $netgeo::whois{$id} = $whois;
   }

   $whois;
}

package Whois::ARIN;

use Date::Parse;

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
   
   return if $whois =~ /^No match/;

   if ($whois =~ /^To single out one record/m) {
      my $handle;
      while ($whois =~ /\G\S.*\(([A-Z0-9\-]+)\).*\n/mg) {
         $handle = $1;
         #return if $handle =~ /-(RIPE|APNIC)/; # heuristic, but bad because ripe might not have better info
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

use Socket;
use base Whois;

sub sanitize {
   local $_ = $_[1];

   s/^%.*\n//gm;
   s/^\n+//;
   s/\n*$/\n/;

   s/^inetnum:\s+/*in: /gm;
   s/^admin-c:\s+/*ac: /gm;
   s/^tech-c:\s+/*tc: /gm;
   s/^owner-c:\s+/*oc: /gm;
   s/^country:\s+/*cy: /gm;
   s/^phone:\s+/*ph: /gm;
   s/^remarks:\s+/*rm: /gm;
   s/^changed:\s+/*ch: /gm;
   s/^created:\s+/*cr: /gm;
   s/^address:\s+/*ad: /gm;
   s/^status:\s+/*st: /gm;
   s/^inetrev:\s+/*ir: /gm;
   s/^nserver:\s+/*ns: /gm;

   $_;
}

sub ip_request {
   my ($self, $ip) = @_;

   my $whois = $self->whois_request("$self->{rflags}$ip");

   $whois =~ s{
      (2[0-5][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])
      (?:\.
         (2[0-5][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])
         (?:\.
            (2[0-5][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])
            (?:\.
               (2[0-5][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])
            )?
         )?
      )?
      /
      ([0-9]+)
   }{
      my $ip   = inet_aton sprintf "%d.%d.%d.%d", $1, $2, $3, $4;
      my $net  = 1 << (31 - $5);
      my $mask = inet_aton 2 ** 32 - $net;

      my $ip1 = $ip & $mask;
      my $ip2 = $ip1 | inet_aton $net * 2 - 1;
      (inet_ntoa $ip1) . " - " . (inet_ntoa $ip2);
   }gex;

   $whois =~ /^\*in: 0\.0\.0\.0 - 255\.255\.255\.255/
      and return;

   $whois =~ /^\*na: ERX-NETBLOCK/m # ripe(?) 146.230.128.210
      and return;

   $whois =~ /^\*de: This network range is not allocated to /m # APNIC e.g. 24.0.0.0
      and return;

   $whois =~ /^\*de: Not allocated by APNIC/m # APNIC e.g. 189.47.24.97
      and return;

   $whois =~ /^\*ac: XXX0/m # 192.0.0.0
      and return;

   $whois =~ /^\*st: (?:ALLOCATED )?UNSPECIFIED/m
      and return;

   $whois =~ /^%ERROR:/m
      and return;

   #while ($whois =~ s/^\*(?:ac|tc):\s+(\S+)\n//m) {
   #   $whois .= $self->whois_request("-FSTpn $1");
   #}

   #$whois =~ s/^\*(?:pn|nh|mb|ch|so|rz|ny|st|rm):.*\n//mg;

   $whois =~ s/\n+$//;

   $whois;
}

package Whois::RWHOIS;

use base Whois;

sub sanitize {
   local $_ = $_[1];
   s/^%referral\s+/referral:/gm;
   s/^network://gm;
   s/^%.*\n//gm;
   s/^\n+//m;
   s/\n*$/\n/m;

   s/^(\S+):\s*/\L$1: /gm;
   s/^ip-network-block:/*in:/gm;
   s/^country-code:/*cy:/gm;
   s/^tech-contact;i:/*tc:/gm;
   s/^updated:/*ch:/gm;
   s/^street-address:/*ad:/gm;
   s/^org-name:/*rm:/gm;
   s/^created:/*cr:/gm;

   $_;
}

sub ip_request {
   my ($self, $ip) = @_;

   my $whois = $self->whois_request("$ip");

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

package netgeo;

use Socket;
use BerkeleyDB;

sub ip2int($) {
   unpack "N", inet_aton $_[0];
}

sub int2ip($) {
   inet_ntoa pack "N", $_[0];
}

our %WHOIS;

#$WHOIS{ARIN}    = new Whois::ARIN ARIN  => "whois.arin.net",    port =>   43, maxjobs => 12;
$WHOIS{ARIN}    = new Whois::RWHOIS ARIN   => "rwhois.arin.net",   port => 4321, maxjobs => 1;
$WHOIS{RIPE}    = new Whois::RIPE RIPE     => "whois.ripe.net",    port =>   43, rflags => "-FTin ", maxjobs => 1;
$WHOIS{AFRINIC} = new Whois::RIPE AFRINIC  => "whois.afrinic.net", port =>   43, rflags => "-FTin ", maxjobs => 1;
$WHOIS{APNIC}   = new Whois::RIPE APNIC    => "whois.apnic.net",   port =>   43, rflags => "-FTin ", maxjobs => 1;
$WHOIS{LACNIC}  = new Whois::RIPE LACNIC   => "whois.lacnic.net",  port =>   43, maxjobs => 1;

$whoislock = new Coro::SemaphoreSet;

sub ip_request {
   my $ip = $_[0];

   my $guard = $whoislock->guard($ip);

   my $c = $iprange->db_cursor;
   my $v;

   if (!$c->c_get((inet_aton $ip), $v, DB_SET_RANGE)) {
      my ($ip0, $ip1, $whois) = split /\x0/, $v;
      my $_ip = ip2int $ip;
      if ($ip0 <= $_ip && $_ip <= $ip1) {
         return $whois;
      }
   }

   my ($arin, $ripe, $apnic);

   $whois = $WHOIS{RIPE}->ip_request($ip)
         || $WHOIS{APNIC} ->ip_request($ip)
         || $WHOIS{AFRINIC} ->ip_request($ip)
         || $WHOIS{LACNIC}->ip_request($ip)
         || $WHOIS{ARIN} ->ip_request($ip)
         ;

   $whois =~ /^\*in: ([0-9.]+)\s+-\s+([0-9.]+)\s*$/mi
      or do { warn "$whois($ip): no addresses found\n", last };

   my ($ip0, $ip1) = ($1, $2);

   my $_ip  = ip2int($ip);
   my $_ip0 = ip2int($ip0);
   my $_ip1 = ip2int($ip1);

   if ($_ip0 + 256 < $_ip1) {
      $_ip  = $_ip & 0xffffff00;
      $_ip0 = $_ip       if $_ip0 < $_ip;
      $_ip1 = $_ip + 255 if $_ip1 > $_ip + 255;
   }

   $iprange->db_put((pack "N", $_ip1), (join "\x0", $_ip0, $_ip1, $whois));
   (tied %whois)->db_sync;
   $iprange->db_sync;

   $whois;
}

sub clear_cache() {
   %netgeo::whois = ();
   $netgeo::iprange->truncate (my $dummy);
}

if (0) {
   #print ip_request "68.52.164.8"; # goof
   #print "\n\n";
   #print ip_request "200.202.220.222"; # lacnic
   #print "\n\n";
   #print ip_request "62.116.167.250";
   #print "\n\n";
   #print ip_request "133.11.128.254"; # jp
   #print "\n\n";
   print ip_request "80.131.153.93";
   print "\n\n";
}

1;


