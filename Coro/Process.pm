=head1 NAME

Coro::Process - coroutine process abstraction

=head1 SYNOPSIS

 use Coro::Process;

 async {
    # some asynchroneous thread of execution
 };

 yield;

=head1 DESCRIPTION

=over 4

=cut

package Coro::Process;

use base Coro;
use base Exporter;

@EXPORT = qw(async yield schedule);

my $idle = Coro::_newprocess {
   &yield while 1;
};

# we really need priorities...
my @ready = ($idle); # the ready queue. hehe ;)

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

# dynamic methods

sub new {
   my $class = shift;
   my $proc = shift;
   my $self = $class->SUPER::new(sub { &$proc; schedule });
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

