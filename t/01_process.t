$|=1;
print "1..3\n";

use Coro;

sub p1 : Coro {
   print "ok 2\n";
}

print "ok 1\n";
yield;
print "ok 3\n";

