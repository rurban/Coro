use ExtUtils::MakeMaker;

if ($] < 5.006) {
   print <<EOF;

***
*** WARNING: This module is quite low-level and uses undocumented perl
*** internals to do it's job. While it seems to work fine with perl-5.8,
*** 5.7 and 5.6, it has not been tested with older versions. If it
*** compiles and passes the testsuite, it should work.  Otherwise you
*** should either upgrade or contact the author, maybe it can be made to
*** work...
***
*** Marc Lehmann <pcg\@goof.com>
***

EOF
}

$EVENT = eval { require Event };

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
       Event	=> 0.83, # still, 0.83 and below have serious bugs(!)
    },
    PM           => {
    		    'Coro.pm'		=> '$(INST_LIBDIR)/Coro/Coro.pm',
    		    'Coro/State.pm'	=> '$(INST_LIBDIR)/Coro/State.pm',

    		    'Coro/MakeMaker.pm'	=> '$(INST_LIBDIR)/Coro/MakeMaker.pm',
    		    'Coro/CoroAPI.h'	=> '$(INST_LIBDIR)/Coro/CoroAPI.h',

    		    'Coro/Cont.pm'	=> '$(INST_LIBDIR)/Coro/Cont.pm',

    		    'Coro/Specific.pm'	=> '$(INST_LIBDIR)/Coro/Specific.pm',

    		    'Coro/Signal.pm'	=> '$(INST_LIBDIR)/Coro/Signal.pm',
    		    'Coro/Channel.pm'	=> '$(INST_LIBDIR)/Coro/Channel.pm',
    		    'Coro/Semaphore.pm'	=> '$(INST_LIBDIR)/Coro/Semaphore.pm',
    		    'Coro/RWLock.pm'	=> '$(INST_LIBDIR)/Coro/RWLock.pm',

                    $EVENT ? (
                       'Event/Event.pm'	=> '$(INST_LIBDIR)/Coro/Event.pm',
                       'Event/Handle.pm'=> '$(INST_LIBDIR)/Coro/Handle.pm',
                       'Event/Socket.pm'=> '$(INST_LIBDIR)/Coro/Socket.pm',
                       'Event/Util.pm'	=> '$(INST_LIBDIR)/Coro/Util.pm',
                    ) : (),
                  },
);

sub MY::postamble {
   <<EOF;

# set \$VERSION in all modules
setver:
	\$(PERL) -pi -e 's/^(\\s*\\\$\$VERSION\\s*=\\s*).*\$\$/\$\${1}\$(VERSION);/' *.pm Coro/*.pm

EOF
}


