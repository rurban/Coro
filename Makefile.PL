use ExtUtils::MakeMaker;

if ($] < 5.006) {
   print <<EOF;

***
*** WARNING: This module is quite low-level and uses undocumented perl
*** internals to do it's job. While it seems to work fine with perl-5.8,
*** 5.7 and 5.6, it has not been tested with older versions. If it
*** compiles and passes the testsuite, it should work.  Otherwise you
*** should either upgrade or fix it ;)
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
       Event		=> 0.85,
       Scalar::Util	=> 0.00,
    },
    PM           => {
    		    'Coro.pm'		=> '$(INST_LIBDIR)/Coro.pm',
                    },
);

sub MY::postamble {
   <<EOF;

# set \$VERSION in all modules
setver:
	\$(PERL) -pi -e 's/^(\\s*\\\$\$VERSION\\s*=\\s*).*\$\$/\$\${1}\$(VERSION);/' *.pm Coro/*.pm Event/*.pm

EOF
}


