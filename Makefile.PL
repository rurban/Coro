use ExtUtils::MakeMaker;

unless (-e "Coro/libcoro/coro.c") {
   print <<EOF;

***
*** ERROR: Coro/libcoro is missing or damaged. If you used a CVS check-out
*** of Coro, you also have to check-out the "libcoro" module from the same CVS
*** repository in the Coro subdirectory (i.e. Coro/Coro/libcoro from outside).
***

EOF
   exit 1;
}

print "*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***\n\n";

if ($] < 5.006) {
   print <<EOF;

***
*** WARNING: This module is quite low-level and uses undocumented perl
*** internals to do it's job. While it seems to work fine with perl-5.[6-10]
*** it has not been tested with older versions. If it compiles and passes the
*** testsuite, it should work. Otherwise you should either upgrade or fix it ;)
***
*** Marc Lehmann <schmorp\@schmorp.de>
***

EOF
}

if (eval { require Event }) {
   if ($Event::VERSION < 0.86 or $Event::VERSION == 0.88) {
      print <<EOF

*** 
*** WARNING: Event version $Event::VERSION found, NOT building Event support.
***
*** This version of Event is broken. The only currently known non-broken
*** versions of Event are 0.87 and 0.89+. Please install one of those
*** versions.
***

EOF
   } else {
      $EVENT = 1;
      $DEFINE .= " -DHAVE_EVENT=1";
      print "\nEvent version $Event::VERSION found, building Event support.\n\n";
   }
} else {
   print "\n*** Event not found, not build Event support.\n\n";
}

if (eval { require EV }) {
   $EV = 1;
   $DEFINE .= " -DHAVE_EV=1";
   print "\nEV version $EV::VERSION found, building EV support.\n\n";
} else {
   print "\n*** EV not found, not build EV support.\n\n";
}

WriteMakefile(
    dist         => {
       PREOP	=> 'pod2text Coro.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
       COMPRESS	=> 'gzip -9v',
       SUFFIX	=> '.gz',
	            },
    NAME         => "Coro",
    VERSION_FROM => "Coro.pm",
    DIR          => ['Coro', ($EVENT ? 'Event' : ()), ($EV ? "EV" : ())],
    PREREQ_PM    => {
       Scalar::Util	=> 0.00,
       AnyEvent         => 2.6,
       Storable		=> 2.15,
       Time::HiRes      => 0,

       # for Coro::Event
       Event		=> 1.06,

       # for Coro::EV
       EV               => 1.3,

       # for Coro::AIO
       IO::AIO          => 2.3,
    },
    EXTRA_META => q{
configure_requires:
  Event: 1.06
  EV: 1.3
    },
    PM           => {
    		    'Coro.pm'		=> '$(INST_LIBDIR)/Coro.pm',

    		    'Coro/State.pm'	=> '$(INST_LIBDIR)/Coro/State.pm',

    		    'Coro/MakeMaker.pm'	=> '$(INST_LIBDIR)/Coro/MakeMaker.pm',
    		    'Coro/CoroAPI.h'	=> '$(INST_LIBDIR)/Coro/CoroAPI.h',

#    		    'Coro/Cont.pm'	=> '$(INST_LIBDIR)/Coro/Cont.pm',

    		    'Coro/Specific.pm'	=> '$(INST_LIBDIR)/Coro/Specific.pm',

    		    'Coro/Timer.pm'	=> '$(INST_LIBDIR)/Coro/Timer.pm',
    		    'Coro/Signal.pm'	=> '$(INST_LIBDIR)/Coro/Signal.pm',
    		    'Coro/Channel.pm'	=> '$(INST_LIBDIR)/Coro/Channel.pm',
    		    'Coro/Semaphore.pm'	=> '$(INST_LIBDIR)/Coro/Semaphore.pm',
    		    'Coro/SemaphoreSet.pm'=> '$(INST_LIBDIR)/Coro/SemaphoreSet.pm',
    		    'Coro/RWLock.pm'	=> '$(INST_LIBDIR)/Coro/RWLock.pm',

    		    'Coro/Debug.pm'	=> '$(INST_LIBDIR)/Coro/Debug.pm',
    		    'Coro/Util.pm'	=> '$(INST_LIBDIR)/Coro/Util.pm',
    		    'Coro/Select.pm'	=> '$(INST_LIBDIR)/Coro/Select.pm',
    		    'Coro/Handle.pm'	=> '$(INST_LIBDIR)/Coro/Handle.pm',
    		    'Coro/Socket.pm'	=> '$(INST_LIBDIR)/Coro/Socket.pm',

    		    'Coro/AIO.pm'	=> '$(INST_LIBDIR)/Coro/AIO.pm',
    		    'Coro/LWP.pm'	=> '$(INST_LIBDIR)/Coro/LWP.pm',
    		    'Coro/Storable.pm'	=> '$(INST_LIBDIR)/Coro/Storable.pm',
                    },
);

sub MY::postamble {
   <<EOF;

# set \$VERSION in all modules
setver:
	\$(PERL) -pi -e 's/^(\\s*(our\\s*)?\\\$\$VERSION\\s*=\\s*).*\$\$/\$\${1}\$(VERSION);/' *.pm Coro/*.pm Event/*.pm

EOF
}


