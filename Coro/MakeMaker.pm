package Coro::MakeMaker;

BEGIN { eval { require warnings } && warnings->unimport ("uninitialized") }

use Config;
use base 'Exporter';

@EXPORT_OK = qw(&coro_args $installsitearch);

my %opt;

for my $opt (split /:+/, $ENV{PERL_MM_OPT}) {
   my ($k,$v) = split /=/, $opt;
   $opt{$k} = $v;
}

my $extra = $Config{sitearch};

$extra =~ s/$Config{prefix}/$opt{PREFIX}/ if
    exists $opt{PREFIX};

for my $d ($extra, @INC) {
   if (-e "$d/Coro/CoroAPI.h") {
      $installsitearch = $d;
      last;
   }
}

sub coro_args {
   my %arg = @_;
   $arg{INC} .= " -I$installsitearch/Coro";
   %arg;
}

1;
__END__

=head1 NAME

Coro::MakeMaker - MakeMaker glue for the C-level Coro API

=head1 SYNOPSIS

This allows you to control coroutines from C level.

=head1 DESCRIPTION

For optimal performance, hook into Coro at the C-level.  You'll need
to make changes to your C<Makefile.PL> and add code to your C<xs> /
C<c> file(s).

=head1 WARNING

When you hook in at the C-level you get a I<huge> performance gain,
but you also reduce the chances that your code will work unmodified
with newer versions of C<perl> or C<Coro>.  This may or may not be a
problem.  Just be aware, and set your expectations accordingly.

=head1 HOW TO

=head2 Makefile.PL

  use Coro::MakeMaker qw(coro_args);

  # ... set up %args ...

  WriteMakefile(coro_args(%args));

=head2 XS

  #include "CoroAPI.h"

  BOOT:
    I_CORO_API("YourModule");

=head2 API (v21)

 struct CoroAPI {
    I32 Ver;

 };

=cut
