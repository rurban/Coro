use ExtUtils::MakeMaker;
use Event::MakeMaker;

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

WriteMakefile(Event::MakeMaker::event_args(
  NAME         => "Coro::Event",
  VERSION_FROM => "Event.pm",
  DEFINE       => $DEFINE,
  DIR          => [],
  PM           => {
                    'Event.pm'	=> '$(INST_LIBDIR)/Event.pm',
                    'Handle.pm'	=> '$(INST_LIBDIR)/Handle.pm',
                    'Socket.pm'	=> '$(INST_LIBDIR)/Socket.pm',
                    'Util.pm'	=> '$(INST_LIBDIR)/Util.pm',
                  },
));



