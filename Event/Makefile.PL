use ExtUtils::MakeMaker;
use Event::MakeMaker;

use 5.005;

use Config;

$|=1;

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
                       'Select.pm'	=> '$(INST_LIBDIR)/Select.pm',
                  },
));



