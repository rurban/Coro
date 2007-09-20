=head1 NAME

Coro::Debug - various functions that help debugging Coro programs

=head1 SYNOPSIS

 use Coro::Debug;

 our $server = new_server Coro::Debug path => "/tmp/socketpath";

 $ socat readline unix:/tmp/socketpath

=head1 DESCRIPTION

This module provides some debugging facilities. Most will, if not handled
carefully, severely compromise the security of your program, so use it
only for debugging (or take other precautions).

It mainly implements a very primitive debugger that lets you list running
coroutines:

   > ps
       pid RUND description where
   8024992 ----             [/localvol/root/src/Coro/blib/lib/Coro.pm:544]
   8024688 --N-             <unknown>
   8024512 ----             [/localvol/root/src/Coro/blib/lib/Coro/Event.pm:166]

Lets you do backtraces on about any coroutine:

   > bt 8024992
   coroutine is at /localvol/root/src/Coro/blib/lib/Coro.pm line 544
   eval {...} called at /localvol/root/src/Coro/blib/lib/Coro.pm line 544
   Coro::__ANON__ called at x line 0
   Coro::_run_coro called at x line 0

Or lets you eval perl code:

   > p 5+7
   12

Or lets you eval perl code within other coroutines:

   > eval 8024512 $_
   1

=over 4

=cut

package Coro::Debug;

use strict;

use Carp ();
use IO::Socket::UNIX;
use AnyEvent;

use Coro ();
use Coro::Handle ();
use Coro::State ();

sub find_coro {
   my ($pid) = @_;
   if (my ($coro) = grep $_ == $1, Coro::State::list) {
      $coro
   } else {
      print "$pid: no such coroutine\n";
      undef
   }
}

=item command $string

Execute a debugger command, sending any output to STDOUT. Used by
C<session>, below.

=cut

sub command($) {
   my ($cmd) = @_;

   $cmd =~ s/[\012\015]$//;

   if ($cmd =~ /^ps/) {
      printf "%20s %s%s%s%s %4s %-20.20s %s\n", "pid", "R", "U", "N", "D", "RSS", "description", "where";
      for my $coro (Coro::State::list) {
         my @bt;
         $coro->_eval (sub { @bt = caller });
         printf "%20s %s%s%s%s %4d %-20.20s %s\n",
                $coro+0,
                $coro->is_ready     ? "R" : "-",
                $coro->is_running   ? "U" : "-",
                $coro->is_new       ? "N" : "-",
                $coro->is_destroyed ? "D" : "-",
                $coro->rss / 1024,
                $coro->debug_desc,
                (@bt ? sprintf "[%s:%d]", $bt[1], $bt[2] : "<unknown>");
      }

   } elsif ($cmd =~ /bt\s+(\d+)/) {
      if (my $coro = find_coro $1) {
         my $bt;
         $coro->_eval (sub { $bt = Carp::longmess "coroutine is" });
         if ($bt) {
            print $bt;
         } else {
            print "$1: unable to get backtrace\n";
         }
      }

   } elsif ($cmd =~ /p\s+(.*)$/) {
      print $@ ? $@ : (join " ", (eval $1), "\n");

   } elsif ($cmd =~ /eval\s+(\d+)\s+(.*)$/) {
      if (my $coro = find_coro $1) {
         my $cmd = $2;
         my @res;
         $coro->_eval (sub { my @res = eval $cmd });
         print $@ ? $@ : (join " ", @res, "\n");
      }

   } elsif ($cmd =~ /^help/) {
      print <<EOF;
ps			show the list of all coroutines
bt <pid>		show a full backtrace of coroutine <pid>
p <perl>		evaluate <perl> expression and print results
eval <pid> <perl>	evaluate <perl> expression in context of <pid> (dangerous!)
exit			end this session

EOF

   } else {
      print "$cmd: unknown command\n";
   }
}

=item session $fh

Run an interactive debugger session on the given filehandle. Each line entered
is simply passed to C<command>

=cut

sub session($) {
   my ($fh) = @_;

   $fh = Coro::Handle::unblock $fh;
   select $fh;

   print "coro debug session. use help for more info\n\n";

   while ((print "> "), defined (my $cmd = $fh->readline ("\012"))) {
      if ($cmd =~ /^exit/) {
         print "bye.\n";
         last;
      }

      command $cmd;
   }
}

=item $server = new_unix_server Coro::Debug $path

Creates a new unix domain socket that listens for connection requests and
runs C<session> on any connection. Normal unix permission checks and umask
applies, so you can protect your socket by puttint it into a protected
directory.

The C<socat> utility is an excellent way to connect to this socket,
offering readline and history support:

   socat readline:history=/tmp/hist.corodebug unix:/path/to/socket

The server accepts connections until it is destroyed, so you should keep
the return value around as long as you want the server to stay available.

=cut

sub new_unix_server {
   my ($class, $path) = @_;

   unlink $path;
   my $fh = new IO::Socket::UNIX Listen => 1, Local => $path
      or Carp::croak "Coro::Debug::Server($path): $!";

   my $self = bless {
      fh   => $fh,
      path => $path,
   }, $class;

   $self->{cw} = AnyEvent->io (fh => $fh, poll => 'r', cb => sub {
      Coro::async_pool {
         $Coro::current->desc ("Coro::Debug server");
         my $fh = $fh->accept;
         session $fh;
         close $fh;
      };
   });

   $self
}

sub DESTROY {
   my ($self) = @_;

   unlink $self->{path};
   close $self->{fh};
   %$self = ();
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut


