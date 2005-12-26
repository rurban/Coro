=head1 NAME

Coro::Util - various utility functions.

=head1 SYNOPSIS

 use Coro::Util;

=head1 DESCRIPTION

This module implements various utility functions, mostly replacing perl
functions by non-blocking counterparts.

=over 4

=cut

package Coro::Util;

BEGIN { eval { require warnings } && warnings->unimport ("uninitialized") }

#use Carp qw(croak);

use Coro::Handle;
use Coro::Semaphore;

use base 'Exporter';

@EXPORT = qw(
   gethostbyname gethostbyaddr
);

$VERSION = 1.7;

$MAXPARALLEL = 16; # max. number of parallel jobs

my $jobs = new Coro::Semaphore $MAXPARALLEL;

sub _do_asy(&;@) {
   require POSIX; # just for _exit

   my $sub = shift;
   $jobs->down;
   my $fh;
   if (0 == open $fh, "-|") {
      syswrite STDOUT, join "\0", map { unpack "H*", $_ } &$sub;
      POSIX::_exit(0);
   }
   my $buf;
   $fh = unblock $fh;
   $fh->sysread($buf, 16384);
   close $fh;
   $jobs->up;
   my @r = map { pack "H*", $_ } split /\0/, $buf;
   wantarray ? @r : $r[0];
}

=item gethostbyname, gethostbyaddr

Work exactly like their perl counterparts, but do not block. Currently
this is being implemented by forking, so it's not exactly low-cost.

=cut

my $netdns = eval { require Net::DNS::Resolver; new Net::DNS::Resolver; 0 };

sub gethostbyname($) {
   if ($netdns) {
      #$netdns->query($_[0]);
      die;
   } else {
      _do_asy { gethostbyname $_[0] } @_;
   }
}

sub gethostbyaddr($$) {
   if ($netdns) {
      die;
   } else {
      _do_asy { gethostbyaddr $_[0], $_[1] } @_;
   }
}

1;

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

