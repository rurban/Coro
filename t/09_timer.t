$|=1;
print "1..4\n";

use Coro;
use Coro::Signal;
use Coro::Timer;

print "ok 1\n";

my $signal = new Coro::Signal;

my $timeout = Coro::Timer::timeout 3;

print $signal->timed_wait(1) ? "not ok" : "ok", " 2\n";

print $timeout ? "not ok" : "ok", " 3\n";

Coro::Timer::sleep 2;

print $timeout ? "ok" : "not ok", " 4\n";

