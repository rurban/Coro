=head1 NAME

Coro::Process - coroutine process abstraction

=head1 SYNOPSIS

 use Coro::Process;

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

package Coro::Process;

use base Coro;
use base Exporter;

$VERSION = 0.01;

@EXPORT = qw(async yield schedule);

{
   use subs 'async';

   my @async;

   sub import {
      Coro::Process->export_to_level(1, @_);
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

my $idle = Coro::_newprocess {
   &yield while 1;
};

# we really need priorities...
my @ready = ($idle); # the ready queue. hehe, rather broken ;)

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
   new Coro::Process $_[0];
}

=item schedule

Calls the scheduler. Please note that the current process will not be put
into the ready queue, so calling this function usually means you will
never be called again.

=cut

sub schedule {
   shift(@ready)->resume;
}

=item yield

Yield to other processes. This function puts the current process into the
ready queue and calls C<schedule>.

=cut

sub yield {
   $Coro::current->ready;
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

=item new Coro::Process \&sub;

Create a new process and return it. Whent he sub returns the process automatically terminates.

=cut

sub new {
   my $class = shift;
   my $proc = shift;
   my $self = $class->SUPER::new(sub { &$proc; &terminate });
   push @ready, $self;
   $self;
}

=item $process->ready

Put the current process into the ready queue.

=cut

# supplement the base class, this really is a bug!
sub Coro::ready {
   push @ready, $_[0];
}

=back

1;

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

