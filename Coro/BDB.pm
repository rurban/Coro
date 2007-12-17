=head1 NAME

Coro::BDB - truly asynchronous bdb access

=head1 SYNOPSIS

   use BDB;
   use Coro::BDB;

   # can now use any of the bdb requests

=head1 DESCRIPTION

This module implements a thin wrapper around the L<BDB|BDB> module.

Each BDB request that could block and doesn't get passed a callback will
normally block all coroutines. after loading this module, this will no
longer be the case.

It will also register an AnyEvent handler (this will be done when the
module gets loaded and thus detects the event model at the same time, so
you need to laod your event module before Coro::BDB).

This module does not export anything (unlike Coro::AIO), as BDB already
supports leaving out the callback.

The AnyEvent watcher can be disabled by executing C<undef
$Coro::BDB::WATCHER>. Please notify the author of when and why you think
this was necessary.

=over 4

=cut

package Coro::BDB;

no warnings;
use strict;

use Coro ();
use AnyEvent;
use BDB ();

use base Exporter::;

our $VERSION = '1.0';
our $WATCHER;

if (AnyEvent::detect =~ /^AnyEvent::Impl::(?:Coro)?EV$/) {
   $WATCHER = EV::io BDB::poll_fileno, EV::READ, \&BDB::poll_cb;
} else {
   our $FH; open $FH, "<&=" . BDB::poll_fileno;
   $WATCHER = AnyEvent->io (fh => $FH, poll => 'r', cb => \&BDB::poll_cb);
}

BDB::set_sync_prepare {
   my $status;
   my $current = $Coro::current;
   (
      sub {
         $status = $!;
         $current->ready; undef $current;
      },
      sub {
         Coro::schedule while defined $current;
         $! = $status;
      },
   )
};

=back

=head1 SEE ALSO

L<BDB> of course.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1
