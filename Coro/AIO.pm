=head1 NAME

Coro::AIO - truly asynchronous file and directrory I/O

=head1 SYNOPSIS

   use Coro::AIO;

   # can now use any of
   # aio_sendfile aio_read aio_write aio_open aio_close aio_stat aio_lstat
   # aio_unlink aio_rmdir aio_readdir aio_scandir aio_symlink aio_fsync
   # aio_fdatasync aio_readahead

   # read 1MB of /etc/passwd, without blocking other coroutines
   my $fh = aio_open "/etc/passwd", O_RDONLY, 0
      or die "/etc/passwd: $!";
   aio_read $fh, 0, 1_000_000, my $buf, 0
      or die "aio_read: $!";
   aio_close $fh;

=head1 DESCRIPTION

This module implements a thin wrapper around L<IO::AIO|IO::AIO>. All of
the functions that expect a callback are being wrapped by this module.

The API is exactly the same as that of the corresponding IO::AIO routines,
except that you have to specify I<all> arguments I<except> the callback
argument. Instead the routines return the values normally passed to the
callback. Everything else, including C<$!> and perls stat cache, are set
as expected after these functions return.

You can mix calls to C<IO::AIO> functions with calls to this module. You
I<must not>, however, call these routines from within IO::AIO callbacks,
as this causes a deadlock. Start a coro inside the callback instead.

You also can, but do not need to, call C<IO::AIO::poll_cb>, as this
module automatically installs an event watcher for the C<IO::AIO> file
descriptor. It uses the L<AnyEvent|AnyEvent> module for this, so please
refer to its documentation on how it selects an appropriate Event module.

For your convienience, here are the changed function signatures, for
documentation of these functions please have a look at L<IO::AIO|the
IO::AIO manual>.

=over 4

=cut

package Coro::AIO;

use strict;

use Coro ();
use AnyEvent;
use IO::AIO ();

use base Exporter::;

our $FH; open $FH, "<&=" . IO::AIO::poll_fileno;
our $WATCHER = AnyEvent->io (fh => $FH, poll => 'r', cb => sub { IO::AIO::poll_cb });

our @EXPORT;

sub wrap($) {
   my ($sub) = @_;

   no strict 'refs';
   
   push @EXPORT, $sub;
   
   my $iosub = "IO::AIO::$sub";
   my $proto = prototype $iosub;

   $proto =~ s/;?\$$// or die "$iosub: unable to remove callback slot from prototype";

   eval qq{
#line 1 "Coro::AIO::$sub($proto)"
      sub $sub($proto) {
         my \$current = \$Coro::current;
         my \$stat;
         my \@res;

         push \@_, sub {
            \$stat = Coro::_aio_get_state;
            \@res = \@_;
            \$current->ready;
            undef \$current;
         };

         &$iosub;

         Coro::schedule while \$current;

         Coro::_aio_set_state \$stat;
         wantarray ? \@res : \$res[0]
      }
   };
   die if $@;
}

wrap $_ for qw(aio_sendfile aio_read aio_write aio_open aio_close aio_stat
               aio_lstat aio_unlink aio_rmdir aio_readdir aio_scandir
               aio_symlink aio_fsync aio_fdatasync aio_readahead);

=item $fh = aio_open $pathname, $flags, $mode

=item $status = aio_close $fh

=item $retval = aio_read  $fh,$offset,$length, $data,$dataoffset

=item $retval = aio_write $fh,$offset,$length, $data,$dataoffset

=item $retval = aio_sendfile $out_fh, $in_fh, $in_offset, $length

=item $retval = aio_readahead $fh,$offset,$length

=item $status = aio_stat $fh_or_path
      
=item $status = aio_lstat $fh

=item $status = aio_unlink $pathname

=item $status = aio_rmdir $pathname

=item $entries = aio_readdir $pathname

=item ($dirs, $nondirs) = aio_scandir $path, $maxreq

=item $status = aio_fsync $fh

=item $status = aio_fdatasync $fh

=back

=head1 SEE ALSO

L<Coro::Socket> and L<Coro::Handle> for non-blocking file operation.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1
