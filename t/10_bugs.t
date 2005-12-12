$|=1;
print "1..3\n";

use Coro;

print "ok 1\n";

async {
      print "ok 2\n";
      $1
}->join;

print "ok 3\n";
