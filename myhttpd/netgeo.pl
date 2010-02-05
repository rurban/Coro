#!/usr/bin/perl

# APNIC refer: KRNIC (for 211.104.0.0)

use Socket;
use Fcntl;

use AnyEvent;
use Coro;
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

use Socket;
use Coro::AnyEvent ();
use Date::Parse;

sub new {
   my $class = shift;
   my $name = shift;
   my $ip = shift;
   my $self = bless { name => $name, ip => $ip, @_ }, $class;

   $self->{maxjobs} = new Coro::Semaphore $self->{maxjobs} || 1;

   $self
}

sub sanitize {
   local $_ = $_[0];

   s/\015?\012/\n/g;
   s/\n[\t ]{6,}([0-9.]+ - [0-9.]+)/ $1/g;

   $_
}

sub whois_request {
   my ($self, $query) = @_;

   my $id = "$self->{name}\x00$query";
   my $whois = $netgeo::whois{$id};

   unless (defined $whois) {
      print "WHOIS($self->{name},$query)\n";

      my $guard = $self->{maxjobs}->guard;
      my $timeout = 5;

      while () {
         my $fh = new Coro::Socket
                         PeerAddr => $self->{ip},
                         PeerPort => $self->{port} || "whois",
                         Timeout  => 30;

         if ($fh) {
            print $fh "$query\n";
            $fh->read ($whois, 16*1024); # max 16k. whois stored
            undef $fh;

            sanitize $whois;

            if ($whois eq ""
                or ($whois =~ /query limit/i && $whois =~ /exceeded/i) # ARIN
                or ($whois =~ /wait a while and try again/i) # ARIN
                or ($whois =~ /^%ERROR:202:/) # RIPE/APNIC
            ) {
               print "retrying in $timeout seconds\n";#d#

               Coro::AnyEvent::sleep $timeout;

               $timeout *= 3;
            } else {
               last;
            }
         } else {
            print STDERR "unable to connect to $self->{ip} ($self->{name}), retrying...\n";
            Coro::AnyEvent::sleep 60;
         }
      }

      $netgeo::whois{$id} = $whois;
   }

   $whois
}

sub mangle_rwhois {
   die "rwhois: RIPE delegation"
     if /^OrgName:\s*RIPE Network Coordination Centre/m;

   /^network:ID:\s*(.*)$/m
      or die "rwhois($_): no network ID";
   my $na = $1;

   /^network:IP-Network-Block:\s*([0-9.]+\s*-\s*[0-9.]+)\s*$/m
      or die "rwhois($_): no network block\n";
   my $in = $1;

   /^network:Country-Code:\s*(.*)/m
      or die "rwhois($_): no country code\n";
   my $cy = $1;

   $_ = <<EOF;
*in: $in
*na: $na
*cy: $cy

$_
EOF
}

sub mangle_arin {
   die "arin: RIPE delegation"
     if /^OrgName:\s*RIPE Network Coordination Centre/mi;

   /^NetName:\s*(.*)$/m
      or die "arin($_): no network name";
   my $na = $1;

   /^NetRange:\s*([0-9.]+\s*-\s*[0-9.]+)\s*$/m
      or die "arin($_): no network block\n";
   my $in = $1;

   /^Country:\s*(.*)/mi
      or die "arin($_): no country code\n";
   my $cy = $1;

   $_ = <<EOF;
*in: $in
*na: $na
*cy: $cy

$_
EOF
}

sub mangle_ripe {
   s/^%.*\n//gm;
   s/^\n+//;
   s/\n*$/\n/;

   s/^inetnum:\s+/*in: /gmx;
   s/^admin-c:\s+/*ac: /gmx;
   s/^tech-c: \s+/*tc: /gmx;
   s/^owner-c:\s+/*oc: /gmx;
   s/^country:\s+/*cy: /gmx;
   s/^phone:  \s+/*ph: /gmx;
   s/^remarks:\s+/*rm: /gmx;
   s/^changed:\s+/*ch: /gmx;
   s/^created:\s+/*cr: /gmx;
   s/^address:\s+/*ad: /gmx;
   s/^status: \s+/*st: /gmx;
   s/^inetrev:\s+/*ir: /gmx;
   s/^nserver:\s+/*ns: /gmx;

   s/^descr:  \s+/*de: /gmx;
   s/^person: \s+/*pe: /gmx;
   s/^e-mail: \s+/*em: /gmx;
   s/^owner:  \s+/*ow: /gmx;
   s/^source: \s+/*so: /gmx;
   s/^role:   \s+/*ro: /gmx;
   s/^nic-hdl:\s+/*hd: /gmx;
   s/^mnt-by: \s+/*mb: /gmx;
   s/^route:  \s+/*ru: /gmx;
   s/^origin: \s+/*og: /gmx;
   s/^netname:\s+/*nn: /gmx;
   s/^mnt-lower:\s+/*ml: /gmx;

   s{
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

   /^\*in: 0\.0\.0\.0 - 255\.255\.255\.255/
      and die "whole internet";

   /^\*de: Various Registries/m # ripe 146.0.0.0
      and die;

   /^\*cy: .*is really world wide/m # ripe 146.0.0.0
      and die;

   /^\*de: This network range is not allocated to /m # APNIC e.g. 24.0.0.0
      and die;

   /^\*de: Not allocated by APNIC/m # APNIC e.g. 189.47.24.97
      and die;

   /^\*ac: XXX0/m # 192.0.0.0
      and die;

   /^\*st: (?:ALLOCATED )?UNSPECIFIED/m
      and die;

   /^%ERROR:/m
      and die;
}

sub ip_request {
   my ($self, $ip) = @_;

   my $whois = $self->whois_request ($ip);
   
   return if $whois =~ /^No match/;

   if ($whois =~ /^To single out one record/m) {
      my $handle;
      while ($whois =~ /\G\S.*\(([A-Z0-9\-]+)\).*\n/mg) {
         $handle = $1;
         #return if $handle =~ /-(RIPE|APNIC)/; # heuristic, but bad because ripe might not have better info
      }
      $handle or die "$whois ($ip): unparseable multimatch\n";
      $whois = $self->whois_request ("!$handle");
   }

   # detect format

   for ($whois) {
      if (/^inetnum:/m && /^country:/m) {
         mangle_ripe;
      } elsif (/^network:ID:/m && /^network:Country-Code:/m) {
         mangle_rwhois;
      } elsif (/^NetName:/m && /^Country:/m) {
         mangle_arin;
      } else {
         die "short arin format, error, garbage";
      }
   }

   $whois
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

$WHOIS{ARIN}    = new Whois ARIN    => "rwhois.arin.net",   port => 4321, maxjobs => 1;
$WHOIS{RIPE}    = new Whois RIPE    => "whois.ripe.net",    port =>   43, maxjobs => 1, rflags => "-FTin ";
$WHOIS{AFRINIC} = new Whois AFRINIC => "whois.afrinic.net", port =>   43, maxjobs => 1, rflags => "-FTin ";
$WHOIS{APNIC}   = new Whois APNIC   => "whois.apnic.net",   port =>   43, maxjobs => 1, rflags => "-FTin ";
$WHOIS{LACNIC}  = new Whois LACNIC  => "whois.lacnic.net",  port =>   43, maxjobs => 1;

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

   $whois = eval { $WHOIS{RIPE}    ->ip_request ($ip) }
         || eval { $WHOIS{APNIC}   ->ip_request ($ip) }
         || eval { $WHOIS{AFRINIC} ->ip_request ($ip) }
         || eval { $WHOIS{LACNIC}  ->ip_request ($ip) }
         || eval { $WHOIS{ARIN}    ->ip_request ($ip) }
         ;

   $whois =~ /^\*in: ([0-9.]+)\s+-\s+([0-9.]+)\s*$/mi
      or do {
         warn "$whois($ip): no addresses found\n";
         return <<EOF;
*in: $ip-$ip
*na: whois failure
*cy: XX
EOF
      };

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

   $whois
}

sub clear_cache() {
   %netgeo::whois = ();
   $netgeo::iprange->truncate (my $dummy);
}

if (0) {
   print ip_request "68.52.164.8"; # goof
   #print ip_request "200.202.220.222"; # lacnic
   #print ip_request "62.116.167.250";
   #print ip_request "133.11.128.254"; # jp
#   print ip_request "76.6.7.8";
}

1;


