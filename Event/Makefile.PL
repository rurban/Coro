use ExtUtils::MakeMaker;

use 5.005;

use Config;

$|=1;

if (eval { require Event }) {
   $EVENT = 1;
   $DEFINE .= " -DHAVE_EVENT=1";
   print "\n*** Event version $Event::VERSION found, building Event support.\n",
         "*** Please read the INSTALL file, you might need to patch Event.\n\n";
} else {
   print "\n*** Event not found, not build Event support.\n\n";
   $EVENT = 0;
}

WriteMakefile(
  NAME         => "Coro::Event",
  VERSION_FROM => "Event.pm",
  DEFINE       => $DEFINE,
  DIR          => [],
);



