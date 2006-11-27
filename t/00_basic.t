BEGIN { $| = 1; print "1..6\n"; }
END {print "not ok 1\n" unless $loaded;}
use Coro::State;
$loaded = 1;
print "ok 1\n";

my $main = new Coro::State;
my $proc = new Coro::State \&a;

sub a {
   print "ok 3\n";
   $proc->transfer ($main, 0);
   print "ok 5\n";
   $proc->transfer ($main, 0);
   print "not ok 6\n";
   die;
}

print "ok 2\n";
$main->transfer ($proc, 0);
print "ok 4\n";
$main->transfer ($proc, 0);
print "ok 6\n";

