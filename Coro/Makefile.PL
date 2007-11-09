use ExtUtils::MakeMaker;

use 5.005;

use Config;

$|=1;

$DEFINE = "";

print <<EOF;

*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** 

Coro has a number of configuration options. Due to its maturity, the
defaults that Coro chooses are usually fine, so you can decide to skip
these questions. Only if something went wrong you should select 'n'
here and manually configure Coro, and, of course, report this to the
maintainer :)

EOF

if (prompt ("Skip further questions and use defaults (y/n)?", "y") =~ /[yY]/) {
   $ENV{PERL_MM_USE_DEFAULT} = 1;
}


$DEFINE .= " -DHAVE_MMAP" if $Config{d_mmap} eq "define" && $Config{d_munmap} eq "define";

if (exists $ENV{CORO_INTERFACE}) {
   $iface = $ENV{CORO_INTERFACE};

} elsif ($^O =~ /win32/i or $^O =~ /cygwin/ or $^O =~ /mswin/) {
   $iface = 'w';

} elsif ($^O =~ /irix/) {
   $iface = "i";

} elsif ($^O =~ /linux/) {
   # default to assembly on x86 and x86_64, and setjmp on others
   $iface = $Config{archname} =~ /^(i[3456]86|amd64|x86_64)-/ && $Config{optimize} =~ /-O/ ? "a" : "s";

} elsif ($^O =~ /(free|net|open)bsd/) {
   # FreeBSD 4.x has ucontext.h but no makecontext et al. (see BUGS section of
   # man context). Assume the same problem for all other BSDs.

   # default to assembly on x86 and x86_64, and setjmp on others
   $iface = $Config{archname} =~ /^(i[3456]86|amd64|x86_64)-/ && $Config{optimize} =~ /-O/ ? "a" : "s";

} elsif ($^O =~ /solaris/) {
   $iface = "s";

} elsif ($^O =~ /darwin/) {
   $iface = "s";

} elsif (-e "/usr/include/ucontext.h") { # shame on this heuristic
   $iface = "u";

} else {
   $iface = "s";
}

print <<EOF;

*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** 

Coro can use a number of methods to implement coroutines at the C
level. The default chosen is based on your current confguration and is
correct in most cases, but you still can chose between these alternatives:

u  The unix 'ucontext.h' functions are relatively new and not implemented
   or well-tested in older unices. They allow very fast coroutine creation
   and reasonably fast switching, and, most importantly, are very stable.
   It is, however, usually slower than the other alternatives due to an
   extra syscall done by swapcontext.

s  If the ucontext functions are not working or you don't want
   to use them for other reasons you can try a workaround using
   setjmp/longjmp/sigaltstack (also standard unix functions). Coroutine
   creation is rather slow, but switching is very fast (often much faster
   than with the ucontext functions). Unfortunately, glibc-2.1 and
   below don't even feature a working sigaltstack. You cannot use this
   implementation if some other code uses SIGUSR2 or you plan to
   create coroutines from an alternative signal stack, as both are being
   used for coroutine creation.

a  Handcoded assembly. This is the fastest and most compatible method
   with the least side effects, if it works, that is. It has been tested
   on GNU/Linux x86 and x86_64 systems and should work on all x86/x86_64
   systems using the SVR ELF ABI. This is the recommended method on
   supported platforms. Note that you usually have to compile this module
   with optimisation enabled for this method to work, and also more
   esoteric switches such as -fomit-leaf-frame-pointer might be required.
   When i doubt, use another method, such as (s)etjmp/longjmp.

l  GNU/Linux. Very old GNU/Linux systems (glibc-2.1 and below) need
   this hack. Since it is very linux-specific it is also quite fast and
   recommended even for newer versions; when it works, that is (currently
   x86 and a few others only. If it compiles, it's usually ok). Newer
   glibc versions (>= 2.5) stop working with this implementation again.

i  IRIX. For some reason, SGI really does not like to follow the single
   unix specification (does that surprise you?), so this workaround might
   be needed (it's fast), although [s] and [u] should also work now.

w  Microsoft Windows. Try this on Microsoft Windows, although, as there is
   no standard on how to do this under windows, this might work only on
   cygwin or specific versions of msvc. Your problem, your fix, our patch.

For most systems, the default chosen should be OK. If you experience
problems then you should experiment with this setting and/or turn
optimisations on or off (make OPTIMIZE=-O0).

EOF

retry:

my $r = prompt "Use which implementation,\n" .
               "<s>et/longjump, <u>context, <a>ssembly, <i>rix, <l>inux or <w>indows?",
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
} elsif ($iface eq "w") {
   $DEFINE .= " -DCORO_LOSER";
   print "\nUsing windows-specific implementation\n\n";
} elsif ($iface eq "a") {
   $DEFINE .= " -DCORO_ASM";
   print "\nUsing handcoded assembly implementation\n\n";
} else {
   print "\nUnknown implementation \"$iface\"\n";
   goto retry;
}

print <<EOF;

*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** 

Per-context stack size factor: Depending on your settings, Coro tries to
share the C stack as much as possible, but sometimes it needs to allocate
a new one. This setting controls the maximum size that gets allocated,
and should not be set too high, as memory and address space still is
wasted even if it's not fully used. The value entered will be multiplied
by sizeof(long), which is usually 4 on 32-bit systems, and 8 on 64-bit
systems.

A setting of 16384 (the default) therefore corresponds to a 64k..128k
stack, which usually is ample space (you might even want to try 8192 or
lower if your program creates many coroutines).

On systems supporting mmap and dynamic memory management, the actual
memory usually gets allocated on demand, but with many large stacks you
can still run out of address space on your typical 32 bit platform.

Some perls (mostly threaded ones and perl compiled under linux 2.6) and
some programs (inefficient regexes can use a lot of stack space) may
need much, much more: If Coro segfaults with weird backtraces (e.g. in a
function prologue) or in t/10_bugs.t, you might want to increase this to
65536 or more.

The default should be fine, and can be changed at runtime with
Coro::State::cctx_stacksize.

EOF

my $stacksize = prompt ("C stack size factor?", "16384");
$DEFINE .= " -DCORO_STACKSIZE=$stacksize";

print "using a stacksize of $stacksize * sizeof(long)\n";

print <<EOF;

*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** 

Coro can optionally put a guard area before each stack segment. When the
stack is too small and the access is not too far outside the stack (i.e.
within the guard area), then the program will safely segfault instead of
running into other data. The cost is some additional overhead with is
usually negligible, and extra use of address space.

The guard area size currently needs to be specified in pages (typical
pagesizes are 4k and 8k). The guard area is only enabled on a few
hardcoded architectures and is ignored on others. The actual preprocessor
expression disables this feature if:

   !__i386 && !__x86_64 && !__powerpc && !__m68k \
   && !__alpha && !__mips && !__sparc64

The default, as usual, should be just fine.

EOF

my $stackguard = prompt ("Number of guard pages (0 disables)?", "4");
$DEFINE .= " -DCORO_STACKGUARD=$stackguard";

print <<EOF;

*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** 

Coro can tell valgrind about its stacks and so reduce spurious warnings
where valgrind would otherwise complain about possible stack switches.

Enabling this does not incur visible runtime or memory overhead, but it
requires that you have the <valgrind/valgrind.h> header file available.

Valgrind support is completely optional, so the default of disabling it is
the safe choice.

EOF

my $valgrind = prompt ("Enable valgrind support (y/n)?",
                       -r "/usr/include/valgrind/valgrind.h" ?  "y" : "n");
$DEFINE .= " -DCORO_USE_VALGRIND=1" if $valgrind =~ /[yY]/;


print <<EOF;

*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** 

Coro can use (or even trick) some perl functions into doing what it needs
instead of relying on (some) of its own functions. This might increase
chances that it compiles and works, but it could just as well result in
memory leaks, crashes or silent data corruption. It certainly does result
in slightly slower speed and higher memory consumption, though, so YOU
SHOULD ENABLE IT ONLY AS A LAST RESORT.

EOF

my $use_internals = prompt ("Prefer perl functions over coro functions (y/n)?", "n");
$DEFINE .= " -DCORO_PREFER_PERL_FUNCTIONS=1" if $use_internals =~ /[yY]/;

print <<EOF;

*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** 

EOF

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

