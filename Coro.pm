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

use base Coro::State;
use base Exporter;

$VERSION = 0.03;

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

my $idle = new Coro sub {
   &yield while 1;
};

=item $main

This coroutine represents the main program.

=cut

$main = new Coro;

=item $current

The current coroutine (the last coroutine switched to). The initial value is C<$main> (of course).

=cut

$current = $main;

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
   new Coro $_[0];
}

=item schedule

Calls the scheduler. Please note that the current process will not be put
into the ready queue, so calling this function usually means you will
never be called again.

=cut

my $prev;

sub schedule {
   ($prev, $current) = ($current, shift @ready);
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

Create a new process, put it into the ready queue and return it. When the
sub returns the process automatically terminates.

=cut

sub new {
   my $class = shift;
   my $proc = shift;
   my $self = $class->SUPER::new($proc ? sub { &$proc; &terminate } : $proc);
   $self->ready;
   $self;
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

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

