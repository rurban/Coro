use ExtUtils::MakeMaker;

use 5.006;

WriteMakefile(
    dist	=> {
	            PREOP	=> 'pod2text Coro.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
	            COMPRESS	=> 'gzip -9v',
	            SUFFIX	=> '.gz',
	           },
    NAME => "Coro",
    VERSION_FROM => "Coro.pm",
    DIR  => ['Coro'],
);

