use ExtUtils::MakeMaker;

use 5.006;

use Config;

$DEFINE = "";

$DEFINE .= " -DHAVE_MMAP" if $Config{d_mmap} eq "define" && $Config{d_munmap} eq "define";

if ($^O =~ /windows/) {
   # nop, autodetected
} elsif (-e "/usr/include/ucontext.h") {
   $DEFINE .= " -DHAVE_UCONTEXT_H"; # lame
} else {
   $DEFINE .= " -DHAVE_SETJMP_H -DHAVE_SIGALTSTACK"; # well
}

print <<EOF;

*
* compile config: $DEFINE
*
* if Coro doesn't work on your platform, try to adjust \$DEFINE
* in Coro/Makefile.PL:
*
* -DHAVE_UCONTEXT_H
*    for systems that have working ucontexts
*    (e.g. linux + glibc-2.2.3 and above)
*    (all modern unices)
*
* -DHAVE_SETJMP_H -DHAVE_SIGALTSTACK
*    for other systems
*    (e.g. linux + glibc below 2.2)
*
* and none for microsoft's platform.
*

EOF

WriteMakefile(
  NAME         => "Coro::State",
  VERSION_FROM => "State.pm",
  DEFINE       => $DEFINE,
  DIR          => [],
);



