use ExtUtils::MakeMaker;

use 5.006;

use Config;

$DEFINE = "";

$DEFINE .= " -DHAVE_MMAP" if $Config{d_mmap} eq "define" && $Config{d_munmap} eq "define";

if ($^O =~ /windows/) {
   $DEFINE = " -DCORO_LOOSE";
} elsif ($^O =~ /linux/) {
   $iface = "l";
} elsif (-e "/usr/include/ucontext.h") {
   $iface = "u";
} else {
   $iface = "s";
}

if ($iface) {
   print <<EOF;

Coro has the option of using two different ways to implement coroutines
at the C level:

u  The unix ucontext functions are newer and not implemented in older
   unices (or broken libc's like glibc-2.2.2 and below). They allow very
   fast coroutine creation and fast switching, and, most importantly, are
   very stable.

s  If the ucontext functions are not working or you don't want
   to use them for other reasons you can try a workaround using
   setjmp/longjmp/sigaltstack (also standard unix functions).  Coroutine
   creation is rather slow, but switching is very fast as well (often much
   faster than with the ucontext functions). Unfortunately, glibc-2.1 and
   below don't even feature a working sigaltstack.

l  Older GNU/Linux systems (glibc-2.1 and below) need this hack. Since it is
   very linux-specific it is also quite fast; when it works, that is.

EOF

retry:
   $|=1;
   print "Use which implementation (s, u, l) [$iface]? ";
   my $r = <>;
   $iface = lc $1 if $r =~ /(\S)/;

   if ($iface eq "u") {
      $DEFINE .= " -DCORO_UCONTEXT";
      print "\nUsing ucontext implementation\n\n";
   } elsif ($iface eq "s") {
      $DEFINE .= " -DCORO_SJLJ";
      print "\nUsing setjmp/longjmp/sigaltstack implementation\n\n";
   } elsif ($iface eq "l") {
      $DEFINE .= " -DCORO_LINUX";
      print "\nUsing linux-specific implementation\n\n";
   } else {
      print "\nUnknown implementation \"$iface\"\n";
      goto retry;
   }
} else {
   print "\nUsing microsoft coroutine implementation\n\n";
}

WriteMakefile(
  NAME         => "Coro::State",
  VERSION_FROM => "State.pm",
  DEFINE       => $DEFINE,
  DIR          => [],
);



