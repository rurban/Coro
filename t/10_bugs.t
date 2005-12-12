$|=1;
print "1..3\n";

# test for known buggy perls

use Coro;

print "ok 1\n";

# debian allocates 0.25mb of local variables in Perl_magic_get,
# normal is <<256 bytes.
async {
      print "ok 2\n";
      $1
}->join;

print "ok 3\n";
