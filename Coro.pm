=head1 NAME

Coro - coroutine process abstraction

=head1 SYNOPSIS

 use Coro;

 async {
    # some asynchronous thread of execution
 };

 # alternatively create an async process like this:

 sub some_func : Coro {
    # some more async code
 }

 yield;

=head1 DESCRIPTION

=cut

package Coro;

use Coro::State;

use base Exporter;

$VERSION = 0.05;

@EXPORT = qw(async yield schedule);
@EXPORT_OK = qw($current);

{
   use subs 'async';

   my @async;

   # this way of handling attributes simply is NOT scalable ;()
   sub import {
      Coro->export_to_level(1, @_);
      my $old = *{(caller)[0]."::MODIFY_CODE_ATTRIBUTES"}{CODE};
      *{(caller)[0]."::MODIFY_CODE_ATTRIBUTES"} = sub {
         my ($package, $ref) = (shift, shift);
         my @attrs;
         for (@_) {
            if ($_ eq "Coro") {
               push @async, $ref;
            } else {
               push @attrs, @_;
            }
         }
         return $old ? $old->($package, $name, @attrs) : @attrs;
      };
   }

   sub INIT {
      async pop @async while @async;
   }
}

=item $main

This coroutine represents the main program.

=cut

our $main = new Coro;

=item $current

The current coroutine (the last coroutine switched to). The initial value is C<$main> (of course).

=cut

# maybe some other module used Coro::Specific before...
if ($current) {
   $main->{specific} = $current->{specific};
}

our $current = $main;

=item $idle

The coroutine to switch to when no other coroutine is running. The default
implementation prints "FATAL: deadlock detected" and exits.

=cut

# should be done using priorities :(
our $idle = new Coro sub {
   print STDERR "FATAL: deadlock detected\n";
   exit(51);
};

# we really need priorities...
my @ready = (); # the ready queue. hehe, rather broken ;)

# static methods. not really.

=head2 STATIC METHODS

Static methods are actually functions that operate on the current process only.

=over 4

=item async { ... };

Create a new asynchronous process and return it's process object
(usually unused). When the sub returns the new process is automatically
terminated.

=cut

sub async(&) {
   my $pid = new Coro $_[0];
   $pid->ready;
   $pid;
}

=item schedule

Calls the scheduler. Please note that the current process will not be put
into the ready queue, so calling this function usually means you will
never be called again.

=cut

my $prev;

sub schedule {
   local @_;
   # should be done using priorities :(
   ($prev, $current) = ($current, shift @ready || $idle);
   Coro::State::transfer($prev, $current);
}

=item yield

Yield to other processes. This function puts the current process into the
ready queue and calls C<schedule>.

=cut

sub yield {
   $current->ready;
   &schedule;
}

=item terminate

Terminates the current process.

=cut

sub terminate {
   &schedule;
}

=back

# dynamic methods

=head2 PROCESS METHODS

These are the methods you can call on process objects.

=over 4

=item new Coro \&sub;

Create a new process and return it. When the sub returns the process
automatically terminates. To start the process you must first put it into
the ready queue by calling the ready method.

=cut

sub new {
   my $class = shift;
   my $proc = $_[0];
   bless {
      _coro_state => new Coro::State ($proc ? sub { &$proc; &terminate } : $proc),
   }, $class;
}

=item $process->ready

Put the current process into the ready queue.

=cut

sub ready {
   push @ready, $_[0];
}

=back

=cut

1;

=head1 SEE ALSO

L<Coro::Channel>, L<Coro::Cont>, L<Coro::Specific>, L<Coro::Semaphore>,
L<Coro::Signal>, L<Coro::State>, L<Coro::Event>.

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

