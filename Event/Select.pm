=head1 NAME

Coro::Select - a (slow but event-aware) replacement for CORE::select

=head1 SYNOPSIS

 use Coro::Select; # replace select globally
 use Core::Select 'select'; # only in this module

=head1 DESCRIPTION

This module tries to create a fully working replacement for perl's
C<select> built-in, using C<Event> watchers to do the job, so other
coroutines can run in parallel.

To be effective globally, this module must be C<use>'d before any other
module that uses C<select>, so it should generally be the first module
C<use>'d in the main program.

You can also invoke it from the commandline as C<perl -MCoro::Select>.

=over 4

=cut

package Coro::Select;

use base Exporter;

use Coro;
use Event;

$VERSION = 1.11;

BEGIN {
   @EXPORT_OK = qw(select);
}

sub import {
   my $pkg = shift;
   if (@_) {
      $pkg->export(caller(0), @_);
   } else {
      $pkg->export("CORE::GLOBAL", "select");
   }
}

sub select(;*$$$) { # not the correct prototype, but well... :()
   if (@_ == 0) {
      return CORE::select;
   } elsif (@_ == 1) {
      return CORE::select $_[0];
   } elsif (defined $_[3] && !$_[3]) {
      return CORE::select(@_);
   } else {
      my $current = $Coro::current;
      my $nfound = 0;
      my @w;
      for ([0, 'r'], [1, 'w'], [2, 'e']) {
         my ($i, $poll) = @$_;
         if (defined (my $vec = $_[$i])) {
            my $rvec = \$_[$i];
            for my $b (0 .. (8 * length $vec)) {
               if (vec $vec, $b, 1) {
                  (vec $$rvec, $b, 1) = 0;
                  push @w,
                     Event->io(fd => $b, poll => $poll, cb => sub {
                        (vec $$rvec, $b, 1) = 1;
                        $nfound++;
                        $current->ready;
                     });
               }
            }
         }
      }

      push @w,
         Event->timer(after => $_[3], cb => sub {
            $current->ready;
         });

      Coro::schedule;
      # wait here

      $_->cancel for @w;
      return $nfound;
   }
}

1;

=back

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut


