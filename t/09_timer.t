$|=1;
print "1..6\n";

use Coro;
use Coro::Timer;

print "ok 1\n";

new Coro::Timer after => 0, cb => sub {
   print "ok 2\n";
};
new Coro::Timer after => 1, cb => sub {
   print "ok 4\n";
};
new Coro::Timer after => 0, cb => sub {
   print "ok 3\n";
};
(new Coro::Timer after => 0, cb => sub {
   print "not ok 4\n";
})->cancel;
new Coro::Timer at => time + 2, cb => sub {
   print "ok 5\n";
   $Coro::main->ready;
};

schedule;
print "ok 6\n";
