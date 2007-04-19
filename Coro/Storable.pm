=head1 NAME

Coro::Storable - offer a more fine-grained Storable interface

=head1 SYNOPSIS

 use Coro::Storable;

=head1 DESCRIPTION

This module implements a few functions from the Storable module in a way
so that it cede's more often. Some applications (such as the Crossfire
game server) sometimes need to load large Storable objects without
blocking the server for a long time.

As it seems that Storable is not reentrant, this module also serialises
calls to freeze and thaw between coroutines.

=head1 FUNCTIONS

=over 4

=item $ref = thaw $pst

Retrieve an object from the given $pst, which must have been created with
C<Coro::Storable::freeze> or C<Storable::store_fd>/C<Storable::store>
(sorry, but Storable uses incompatible formats for disk/mem objects).

This works by calling C<Coro::cede> for every 4096 bytes read in.

=item $pst = freeze $ref

Freeze the given scalar into a Storable object. It uses the same format as
C<Storable::nstore_fd> (note the C<n>).

This works by calling C<Coro::cede> for every write that Storable
issues. Unfortunately, Storable often makes many very small writes, so it
is rather inefficient. But it does keep the latency low.

=back

=cut

package Coro::Storable;

use strict;

use Coro ();
use Coro::Semaphore ();

use Storable;
use base "Exporter";

our $VERSION = '0.1';
our @EXPORT = qw(freeze thaw);

my $lock = new Coro::Semaphore;

sub freeze($) {
   my $guard = $lock->guard;

   open my $fh, ">:via(CoroCede)", \my $buf
      or die "cannot open pst via CoroCede: $!";
   Storable::nstore_fd $_[0], $fh;
   $buf
}

sub thaw($) {
   my $guard = $lock->guard;

   open my $fh, "<:via(CoroCede)", \$_[0]
      or die "cannot open pst via CoroCede: $!";
   Storable::fd_retrieve $fh
}

package PerlIO::via::CoroCede;

# generic cede-on-read/write filtering layer

sub PUSHED {
   __PACKAGE__
}

sub FILL {
   Coro::cede;
   read $_[1], my $buf, 4096
      or return undef;
   $buf
}

sub WRITE {
   Coro::cede;
   (print {$_[2]} $_[1]) ? length $_[1] : -1
}

1;

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut


