=head1 NAME

Coro::Debug - various functions that help debugging Coro programs

=head1 SYNOPSIS

 use Coro::Debug;

 our $server = new_server Coro::Debug path => "/tmp/socketpath";

 $ socat readline: unix:/tmp/socketpath

=head1 DESCRIPTION

This module provides some debugging facilities. Most will, if not handled
carefully, severely compromise the security of your program, so use it
only for debugging (or take other precautions).

It mainly implements a very primitive debugger that lets you list running
coroutines:

            state
            |cctx allocated
            ||   resident set size (kb)
   > ps     ||   |
        pid SS  RSS description          where
   43383424 --   10 [async_pool idle]    [/opt/perl/lib/perl5/Coro.pm:256]
   46127008 --    5 worldmap updater     [/opt/cf/ext/item-worldmap.ext:116]
   18334288 --    4 music scheduler      [/opt/cf/ext/player-env.ext:77]
   24559856 --   14 [async_pool idle]    [/opt/perl/lib/perl5/Coro.pm:256]
   20170640 --    6 map scheduler        [/opt/cf/ext/map-scheduler.ext:62]
   18492336 --    5 player scheduler     [/opt/cf/ext/login.ext:501]
   15607952 --    2 timeslot manager     [/opt/cf/cf.pm:382]
   11015408 --    2 [unblock_sub schedul [/opt/perl/lib/perl5/Coro.pm:548]
   11015088 --    2 [coro manager]       [/opt/perl/lib/perl5/Coro.pm:170]
   11014896 US  835 [main::]             [/opt/cf/ext/dm-support.ext:45]

Lets you do backtraces on about any coroutine:

   > bt 18334288
   coroutine is at /opt/cf/ext/player-env.ext line 77
           eval {...} called at /opt/cf/ext/player-env.ext line 77
           ext::player_env::__ANON__ called at -e line 0
           Coro::_run_coro called at -e line 0

Or lets you eval perl code:

   > 5+7
   12

Or lets you eval perl code within other coroutines:

   > eval 18334288 caller(1); $DB::args[0]->method
   1

If your program uses the Coro::Debug::log facility:

   Coro::Debug::log 0, "important message";
   Coro::Debug::log 9, "unimportant message";

Then you can even receive log messages in any debugging session:

   > loglevel 5
   2007-09-26Z02:22:46 (9) unimportant message

=over 4

=cut

package Coro::Debug;

use strict;

use Carp ();
use IO::Socket::UNIX;
use AnyEvent;
use Time::HiRes;

use Coro ();
use Coro::Handle ();
use Coro::State ();

our %log;

sub find_coro {
   my ($pid) = @_;
   if (my ($coro) = grep $_ == $1, Coro::State::list) {
      $coro
   } else {
      print "$pid: no such coroutine\n";
      undef
   }
}

=item log $level, $msg

Log a debug message of the given severity level (0 is highest, higher is
less important) to all interested parties.

=cut

sub log($$) {
   my ($level, $msg) = @_;
   $msg =~ s/\s*$/\n/;
   $_->($level, $msg) for values %log;
}

=item command $string

Execute a debugger command, sending any output to STDOUT. Used by
C<session>, below.

=cut

sub command($) {
   my ($cmd) = @_;

   $cmd =~ s/\s+$//;

   if ($cmd =~ /^ps$/) {
      printf "%20s %s%s %4s %-24.24s %s\n", "pid", "S", "S", "RSS", "description", "where";
      for my $coro (Coro::State::list) {
         Coro::cede;
         my @bt;
         Coro::State::call ($coro, sub {
            # we try to find *the* definite frame that gives msot useful info
            # by skipping Coro frames and pseudo-frames.
            for my $frame (1..10) {
               my @frame = caller $frame;
               @bt = @frame if $frame[2];
               last unless $bt[0] =~ /^Coro/;
            }
         });
         printf "%20s %s%s %4d %-24.24s %s\n",
                $coro+0,
                $coro->is_new ? "N" : $coro->is_running ? "U" : $coro->is_ready ? "R" : "-",
                $coro->has_stack ? "S" : "-",
                $coro->rss / 1000,
                $coro->debug_desc,
                (@bt ? sprintf "[%s:%d]", $bt[1], $bt[2] : "-");
      }

   } elsif ($cmd =~ /^bt\s+(\d+)$/) {
      if (my $coro = find_coro $1) {
         my $bt;
         Coro::State::call ($coro, sub { $bt = Carp::longmess "coroutine is" });
         if ($bt) {
            print $bt;
         } else {
            print "$1: unable to get backtrace\n";
         }
      }

   } elsif ($cmd =~ /^eval\s+(\d+)\s+(.*)$/) {
      if (my $coro = find_coro $1) {
         my $cmd = $2;
         my @res;
         Coro::State::call ($coro, sub { @res = eval $cmd });
         print $@ ? $@ : (join " ", @res, "\n");
      }

   } elsif ($cmd =~ /^help$/) {
      print <<EOF;
ps                      show the list of all coroutines
bt <pid>                show a full backtrace of coroutine <pid>
eval <pid> <perl>       evaluate <perl> expression in context of <pid>
<anything else>         evaluate as perl and print results
<anything else> &       same as above, but evaluate asynchronously
EOF

   } elsif ($cmd =~ /^(.*)&$/) {
      my $cmd = $1;
      my $fh = select;
      Coro::async_pool {
         my $t = Time::HiRes::time;
         my @res = eval $cmd;
         $t = Time::HiRes::time - $t;
         print {$fh}
            "\rcommand: $cmd\n",
            "execution time: $t\n",
            "result: ", $@ ? $@ : (join " ", @res) . "\n",
            "> ";
      };
   } else {
      my @res = eval $cmd;
      print $@ ? $@ : (join " ", @res) . "\n";
   }
}

=item session $fh

Run an interactive debugger session on the given filehandle. Each line entered
is simply passed to C<command>.

=cut

sub session($) {
   my ($fh) = @_;

   $fh = Coro::Handle::unblock $fh;
   select $fh;

   my $loglevel = -1;
   local $log{$Coro::current} = sub {
      return unless $_[0] <= $loglevel;
      my ($time, $micro) = Time::HiRes::gettimeofday;
      my ($sec, $min, $hour, $day, $mon, $year) = gmtime $time;
      my $date = sprintf "%04d-%02d-%02dZ%02d:%02d:%02d.%04d",
                         $year + 1900, $mon + 1, $day + 1, $hour, $min, $sec, $micro / 100;
      print $fh sprintf "\015%s (%d) %s> ", $date, $_[0], $_[1];
   };

   print "coro debug session. use help for more info\n\n";

   while ((print "> "), defined (my $cmd = $fh->readline ("\012"))) {
      if ($cmd =~ /^exit\s*$/) {
         print "bye.\n";
         last;
      } elsif ($cmd =~ /^loglevel\s*(\d+)\s*/) {
         $loglevel = $1;
      } elsif ($cmd =~ /^help\s*/) {
         command $cmd;
         print <<EOF;
loglevel <int>		enable logging for messages of level <int> and lower
exit			end this session
EOF
      } else {
         command $cmd;
      }
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
         $Coro::current->desc ("[Coro::Debug session]");
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


