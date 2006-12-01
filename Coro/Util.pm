=head1 NAME

Coro::Util - various utility functions.

=head1 SYNOPSIS

 use Coro::Util;

=head1 DESCRIPTION

This module implements various utility functions, mostly replacing perl
functions by non-blocking counterparts.

This module is an AnyEvent user. Refer to the L<AnyEvent|AnyEvent>
documentation to see how to integrate it into your own programs.

=over 4

=cut

package Coro::Util;

use strict;

no warnings "uninitialized";

use AnyEvent;

use Coro::State;
use Coro::Semaphore;

use base 'Exporter';

our @EXPORT = qw(gethostbyname gethostbyaddr);
our @EXPORT_OK = qw(inet_aton);

our $VERSION = 2.0;

our $MAXPARALLEL = 16; # max. number of parallel jobs

my $jobs = new Coro::Semaphore $MAXPARALLEL;

sub _do_asy(&;@) {
   my $sub = shift;
   $jobs->down;
   my $fh;

   if (0 == open $fh, "-|") {
      syswrite STDOUT, join "\0", map { unpack "H*", $_ } &$sub;
      Coro::State::_exit 0;
   }

   my $buf;
   my $current = $Coro::current;
   my $w; $w = AnyEvent->io (fh => $fh, poll => 'r', cb => sub {
      sysread $fh, $buf, 16384, length $buf
         and return;

      undef $w;
      $current->ready;
   });

   &Coro::schedule;
   &Coro::schedule while $w;

   $jobs->up;
   my @r = map { pack "H*", $_ } split /\0/, $buf;
   wantarray ? @r : $r[0];
}

sub dotted_quad($) {
   $_[0] =~ /^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[0-9][0-9]?)
            \.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[0-9][0-9]?)
            \.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[0-9][0-9]?)
            \.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[0-9][0-9]?)$/
}

=item gethostbyname, gethostbyaddr

Work exactly like their perl counterparts, but do not block. Currently
this is being implemented with forking, so it's not exactly low-cost.

=cut

my $netdns = eval { die; require Net::DNS::Resolver; new Net::DNS::Resolver; };

sub gethostbyname($) {
   if ($netdns) {
      #$netdns->query($_[0]);
      die;
   } else {
      _do_asy { gethostbyname $_[0] } @_
   }
}

sub gethostbyaddr($$) {
   if ($netdns) {
      die;
   } else {
      _do_asy { gethostbyaddr $_[0], $_[1] } @_
   }
}

=item Coro::Util::inet_aton

Works almost exactly like its Socket counterpart, except that it does not
block. Is implemented with forking, so not exactly low-cost.

=cut

use Socket;

our $inet_aton = \&Socket::inet_aton;

sub inet_aton {
   require Socket;

   if (dotted_quad $_[0]) {
      $inet_aton->($_[0])
   } else {
      _do_asy { $inet_aton->($_[0]) } @_
   }
}

1;

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

