$|=1;
print "1..8\n";

use Coro;
use Coro::Signal;
use Coro::Timer;

print "ok 1\n";

my $signal = new Coro::Signal;

new Coro::Timer after => 0, cb => sub {
   print "ok 2\n";
};
new Coro::Timer at => time + 1, cb => sub {
   print "ok 4\n";
};
new Coro::Timer after => 3, cb => sub {
   $signal->send;
};
new Coro::Timer after => 0, cb => sub {
   print "ok 3\n";
};
(new Coro::Timer after => 0, cb => sub {
   print "not ok 4\n";
})->cancel;
new Coro::Timer at => time + 5, cb => sub {
   print "ok 7\n";
   $Coro::main->ready;
};

print $signal->timed_wait(2) ? "not ok" : "ok", " 5\n";
print $signal->timed_wait(2) ? "ok" : "not ok", " 6\n";
schedule;
print "ok 8\n";
