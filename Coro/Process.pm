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

=over 4

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

sub async(&) {
   new Coro::Process $_[0];
}

sub schedule {
   shift(@ready)->resume;
}

sub yield {
   $Coro::current->ready;
   &schedule;
}

sub terminate {
   &schedule;
}

# dynamic methods

sub new {
   my $class = shift;
   my $proc = shift;
   my $self = $class->SUPER::new(sub { &$proc; &terminate });
   push @ready, $self;
   $self;
}

# supplement the base class, this really is a bug!
sub Coro::ready {
   push @ready, $_[0];
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <pcg@goof.com>
 http://www.goof.com/pcg/marc/

=cut

