$| = 1;

if ($^O eq "cygwin") {
   print "1..0 # skipped: pipe() blocking on cygwin\n";
   exit;
}

print "1..12\n";

use Coro;
use Coro::Event;
use Coro::Handle;

print "ok 1\n";

pipe my ($r, $w) or die;

print "ok 2\n";

$r = unblock $r;
$w = unblock $w;

print "ok 3\n";

async {
   print "ok 5\n";

   do_timer (after => 0.001);

   print "ok 7\n";

   print $w "13\n";

   print "ok 8\n";

   $w->print ($buf, "x" x (1024*128));

   print "ok 10\n";

   print $w "77\n";
   close $w;
};

print "ok 4\n";

cede;

print "ok 6\n";

print <$r> == 13 ? "" : "not ", "ok 9\n";

$r->read ($buf, 1024*128);

print "ok 11\n";

print <$r> == 77 ? "" : "not ", "ok 12\n";


