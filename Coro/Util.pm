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

use Socket ();

use AnyEvent;

use Coro::State;
use Coro::Handle;
use Coro::Storable ();
use Coro::Semaphore;

use base 'Exporter';

our @EXPORT = qw(gethostbyname gethostbyaddr);
our @EXPORT_OK = qw(inet_aton fork_eval);

our $VERSION = 2.0;

our $MAXPARALLEL = 16; # max. number of parallel jobs

my $jobs = new Coro::Semaphore $MAXPARALLEL;

sub _do_asy(&;@) {
   my $sub = shift;
   $jobs->down;
   my $fh;

   my $pid = open $fh, "-|";

   if (!defined $pid) {
      die "fork: $!";
   } elsif (!$pid) {
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
   $_[0] =~ /^(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[0-9][0-9]?)
            \.(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[0-9][0-9]?)
            \.(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[0-9][0-9]?)
            \.(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[0-9][0-9]?)$/x
}

my $has_ev_adns;

sub has_ev_adns {
   ($has_ev_adns ||= do {
      my $model = AnyEvent::detect;
      warn $model;
      (($model eq "AnyEvent::Impl::CoroEV" or $model eq "AnyEvent::Impl::EV")
       && eval { require EV::ADNS })
         ? 2 : 1
   }) - 1
}

=item gethostbyname, gethostbyaddr

Work exactly like their perl counterparts, but do not block. Currently
this is being implemented with forking, so it's not exactly low-cost.

=cut

sub gethostbyname($) {
   if (&dotted_quad) {
      return $_[0];
   } elsif (has_ev_adns) {
      my $current = $Coro::current;
      my @a;
  
      EV::ADNS::submit ($_[0], &EV::ADNS::r_a, 0, sub {
         (undef, undef, @a) = @_;
         $current->ready;
         undef $current;
      });
      Coro::schedule while $current;

      return @a
         ? ($_[0], $_[0], &Socket::AF_INET, 4, map +(Socket::inet_aton $_), @a)
         : ();
   } else {
      return _do_asy { gethostbyname $_[0] } @_
   }
}

sub gethostbyaddr($$) {
   _do_asy { gethostbyaddr $_[0], $_[1] } @_
}

=item Coro::Util::inet_aton

Works almost exactly like its Socket counterpart, except that it does not
block. Is implemented with forking, so not exactly low-cost.

=cut

sub inet_aton {
   if (&dotted_quad) {
      return Socket::inet_aton ($_[0]);
   } elsif (has_ev_adns) {
      my $current = $Coro::current;
      my @a;
 
      EV::ADNS::submit ($_[0], &EV::ADNS::r_a, 0, sub {
         (undef, undef, @a) = @_;
         $current->ready;
         undef $current;
      });
      Coro::schedule while $current;

      return @a ? Socket::inet_aton $a[0] : ();
   } else {
      return _do_asy { Socket::inet_aton $_[0] } @_
   }
}

=item @result = Coro::Util::fork_eval { ... }, @args

Executes the given code block or code reference with the given arguments
in a separate process, returning the results. The return values must be
serialisable with Coro::Storable. It may, of course, block.

Note that using event handling in the sub is not usually a good idea as
you will inherit a mixed set of watchers from the parent.

Exceptions will be correctly forwarded to the caller.

This function is useful for pushing cpu-intensive computations into a
different process, for example to take advantage of multiple CPU's. Its
also useful if you want to simply run some blocking functions (such as
C<system()>) and do not care about the overhead enough to code your own
pid watcher etc.

This function might keep a pool of processes in some future version, as
fork can be rather slow in large processes.

Example: execute some external program (convert image to rgba raw form)
and add a long computation (extract the alpha channel) in a separate
process, making sure that never more then $NUMCPUS processes are being
run.

   my $cpulock = new Coro::Semaphore $NUMCPUS;

   sub do_it {
      my ($path) = @_;

      my $guard = $cpulock->guard;

      Coro::Util::fork_eval {
         open my $fh, "convert -depth 8 \Q$path\E rgba:"
            or die "$path: $!";

         local $/;
         # make my eyes hurt
         pack "C*", unpack "(xxxC)*", <$fh>
      }
   }

   my $alphachannel = do_it "/tmp/img.png";

=cut

sub fork_eval(&@) {
   my ($cb, @args) = @_;

   pipe my $fh1, my $fh2
      or die "pipe: $!";

   my $pid = fork;

   if ($pid) {
      undef $fh2;

      my $res = Coro::Storable::thaw +(Coro::Handle::unblock $fh1)->readline (undef);
      waitpid $pid, 0; # should not block, we expect the child to simply behave

      die $$res unless "ARRAY" eq ref $res;

      return wantarray ? @$res : $res->[-1];

   } elsif (defined $pid) {
      delete $SIG{__WARN__};
      delete $SIG{__DIE__};
      # just in case, this hack effectively disables event processing
      # in the child. cleaner and slower would be to canceling all
      # event watchers, but we are event-model agnostic.
      undef $Coro::idle;
      $Coro::current->prio (Coro::PRIO_MAX);

      eval {
         undef $fh1;

         my @res = eval { $cb->(@args) };

         open my $fh, ">", \my $buf
            or die "fork_eval: cannot open fh-to-buf in child: $!";
         Storable::store_fd $@ ? \"$@" : \@res, $fh;
         close $fh;

         syswrite $fh2, $buf;
         close $fh2;
      };

      warn $@ if $@;
      Coro::State::_exit 0;

   } else {
      die "fork_eval: $!";
   }
}

# make sure store_fd is preloaded
eval { Storable::store_fd undef, undef };

1;

=back

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

