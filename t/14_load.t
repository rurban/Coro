BEGIN { $| = 1; print "1..18\n"; }

my $idx;

for my $module (qw(
   Coro
   Coro::State
   Coro::Signal
   Coro::Semaphore
   Coro::SemaphoreSet
   Coro::Channel
   Coro::Specific
   Coro::RWLock
   Coro::MakeMaker
   Coro::Debug
   Coro::Util
   Coro::LWP
   Coro::Select
   Coro::Handle
   Coro::Socket
   Coro::Timer
   Coro::Storable
   Coro::AnyEvent
)) {
   eval "use $module";
   print $@ ? "not " : "", "ok ", ++$idx, " # $module ($@)\n";
}

