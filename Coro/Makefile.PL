use ExtUtils::MakeMaker;

use 5.005;

use Config;

$|=1;

$DEFINE = "";

$DEFINE .= " -DHAVE_MMAP" if $Config{d_mmap} eq "define" && $Config{d_munmap} eq "define";

if ($^O =~ /windows/) {
   $DEFINE = " -DCORO_LOOSE";
} elsif ($^O =~ /linux/) {
   $iface = "l";
} elsif ($^O =~ /solaris/) {
   $iface = "s";
} elsif (-e "/usr/include/ucontext.h") {
   $iface = "u";
} else {
   $iface = "s";
}

print <<EOF;

Version 0.12 introduced experimental C context sharing. This makes it
possible to share the C stack and context between many coroutines,
resulting in memory savings and slight speed gains, at the cost of
potential segfaults (especially with exception handling). On my Linux/x86
machine this decreased the size of a new coroutine from 9k to 5k, the
savings are much more apparent on machines without mmap or good memory
management. This algorithm relies on the non-fact that the same machine
stack pointer indicates the same function call nesting level, which
usually works good enough but might fail...

The default (disabled) is safe, as it only increases memory consumption.

EOF

print "Do you want to enable experimental context sharing (y/n) [n]? ";

if (<> =~ /^\s*y/i) {
   print "\nExperimental context sharing enabled.\n\n";
   $DEFINE .= " -DCORO_LAZY_STACK";
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
   very linux-specific it is also quite fast for newer versions; when it works,
   that is...

EOF

retry:
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



