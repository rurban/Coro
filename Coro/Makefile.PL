use ExtUtils::MakeMaker;

use 5.005;

use Config;

$|=1;

$DEFINE = "";

$DEFINE .= " -DHAVE_MMAP" if $Config{d_mmap} eq "define" && $Config{d_munmap} eq "define";

if ($^O =~ /win32/i or $^O =~ /cygwin/) {
   $DEFINE = " -DCORO_LOOSE";
} elsif ($^O =~ /irix/) {
   $iface = "i";
} elsif ($^O =~ /linux/) {
   # default to setjmp/longjmp on non-x86...
   $iface = $Config{archname} =~ /^(i[3456]86|amd64)-/ ? "l" : "s";
} elsif ($^O =~ /(free|net|open)bsd/) {
   # FreeBSD 4.x has ucontext.h but no makecontext et al (see BUGS section of
   # man context). Assume the same problem for all other BSDs.
   $iface = "s";
} elsif ($^O =~ /solaris/) {
   $iface = "s";
} elsif ($^O =~ /darwin/) {
   $iface = "s";
} elsif (-e "/usr/include/ucontext.h") {
   $iface = "u";
} else {
   $iface = "s";
}

print <<EOF;

Version 0.12 introduced C context sharing. This makes it possible to share
the C stack and context between many coroutines, resulting in memory
savings and slight speed gains, at the cost of potential (but mostly
theoretical) segfaults. On my Linux/x86 machine this decreased the size
of a new coroutine from 9k to 5k, but the savings are much more apparent
on machines without mmap or good memory management. This algorithm relies
on the non-fact that the same machine stack pointer indicates the same
function call nesting level, which usually works good enough but might
fail...

The default (enabled) has been in-use on productions servers for some time
now, without any problem reports so far.

EOF

if (prompt ("Do you want to enable C context sharing (y/n)", "y") !~ /^\s*n/i) {
   print "\nExperimental context sharing enabled.\n\n";
   $DEFINE .= " -DCORO_LAZY_STACK";
}

if ($iface) {
   print <<EOF;

Coro can use various ways to implement coroutines at the C level:

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
   very linux-specific it is also quite fast for newer versions; when it
   works, that is (currently x86 only)...

i  IRIX. For some reason, SGI really does not like to follow the unix
   standard (does that surprise you?), so this workaround might be needed
   (it's fast), although s and u should also work now.

For most systems, the default chosen should be OK. If you experience
problems then you should experiment with this setting and/or turn off
optimizations (make OPTIMIZE=-O0).

EOF

retry:

   my $r = prompt "Use which implementation,\n" .
                  "<s>etjmp/longjump, <u>context, <i>rix or <l>inux?",
                  $iface;
   $iface = lc $1 if $r =~ /(\S)/;

   if ($iface eq "u") {
      $DEFINE .= " -DCORO_UCONTEXT";
      print "\nUsing ucontext implementation\n\n";
      conftest("TEST_makecontext");
   } elsif ($iface eq "s") {
      $DEFINE .= " -DCORO_SJLJ";
      print "\nUsing setjmp/longjmp/sigaltstack implementation\n\n";
      conftest("TEST_sigaltstack");
   } elsif ($iface eq "l") {
      $DEFINE .= " -DCORO_LINUX";
      print "\nUsing linux-specific implementation\n\n";
   } elsif ($iface eq "i") {
      $DEFINE .= " -DCORO_IRIX";
      print "\nUsing irix-specific implementation\n\n";
   } else {
      print "\nUnknown implementation \"$iface\"\n";
      goto retry;
   }
} else {
   print "\nUsing microsoft compatible coroutines\n\n";
}

WriteMakefile(
  NAME         => "Coro::State",
  VERSION_FROM => "State.pm",
  DEFINE       => $DEFINE,
  DIR          => [],
);

sub conftest {
   my $type = shift;

   print "\nTrying to detect stack growth direction (for $type)\n";
   print "You might see some warnings, this should not concern you.\n\n";
   system "$Config{cc} $Config{ccflags} -D$type libcoro/conftest.c";

   my $res = qx<./a.out>;
   $res =~ s/\s+$//;
   my ($sp, $ss) = split /,/, $res;

   print "\n\n*****************************************************************************\n";
   print "If the testsuite fails PLEASE provide the following information\n";
   print "to Marc Lehmann <schmorp\@schmorp.de>: operating system name, version,\n";
   print "architecture name and this string '$sp|$ss'. Thanks a lot!\n";#d#
   print "*****************************************************************************\n\n";

   unlink "a.out";
   unlink "conftestval";
}

print <<EOF if $^O =~ /linux/;

*****************************************************************************
*                                                                           *
*  HEY!! You are using Linux! That's not at all bad, but if you get seg-    *
*  faults with Coro almost all the time please refer to README.linux-glibc  *
*                                                                           *
*****************************************************************************

EOF

