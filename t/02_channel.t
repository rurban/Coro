$|=1;
print "1..19\n";

use Coro;
use Coro::Process;
use Coro::Channel;

my $q = new Coro::Channel 0;

sub producer : Coro {
   for (1..9) {
      print "ok ", $_*2, "\n";
      $q->put($_);
   }
}

print "ok 1\n";
yield;

for (11..19) {
   my $x = do { local $_; $q->get };
   print $x == $_-10 ? "ok " : "not ok ", ($_-10)*2+1, "\n";
}

