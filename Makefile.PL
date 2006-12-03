use ExtUtils::MakeMaker;

if ($] < 5.006) {
   print <<EOF;

***
*** WARNING: This module is quite low-level and uses undocumented perl
*** internals to do it's job. While it seems to work fine with perl-5.[6-9]
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
   print "\n";
} else {
   print "\n*** Event not found, not build Event support.\n\n";
}

WriteMakefile(
    dist         => {
       PREOP	=> 'pod2text Coro.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
       COMPRESS	=> 'gzip -9v',
       SUFFIX	=> '.gz',
	            },
    NAME         => "Coro",
    VERSION_FROM => "Coro.pm",
    DIR          => ['Coro', ($EVENT ? 'Event' : ())],
    PREREQ_PM    => {
       Scalar::Util	=> 0.00,

       # for Coro::Event
       Event		=> 0.86,

       # for Coro::AIO, Coro::Util
       IO::AIO          => 1.6,
       AnyEvent         => 2.1,
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

    		    'Coro/Util.pm'	=> '$(INST_LIBDIR)/Coro/Util.pm',
    		    'Coro/Select.pm'	=> '$(INST_LIBDIR)/Coro/Select.pm',
    		    'Coro/Handle.pm'	=> '$(INST_LIBDIR)/Coro/Handle.pm',
    		    'Coro/Socket.pm'	=> '$(INST_LIBDIR)/Coro/Socket.pm',

    		    'Coro/AIO.pm'	=> '$(INST_LIBDIR)/Coro/AIO.pm',
    		    'Coro/LWP.pm'	=> '$(INST_LIBDIR)/Coro/LWP.pm',
                    },
);

sub MY::postamble {
   <<EOF;

# set \$VERSION in all modules
setver:
	\$(PERL) -pi -e 's/^(\\s*(our\\s*)?\\\$\$VERSION\\s*=\\s*).*\$\$/\$\${1}\$(VERSION);/' *.pm Coro/*.pm Event/*.pm

EOF
}


