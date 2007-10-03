BEGIN { $| = 1; print "1..8\n"; }
END {print "not ok 1\n" unless $loaded;}
use Coro::State;
$loaded = 1;
print "ok 1\n";

my $main  = new Coro::State;
my $proca = new Coro::State \&a;
my $procb = new Coro::State \&b;

sub a {
   $/ = 77;
   print "ok 3\n";
   $proca->transfer ($main);
   print $/ == 77 ? "" : "not ", "ok 5\n";
   $proca->transfer ($main);
   print "not ok 6\n";
   die;
}

sub b {
   print $/ != 55 ? "not " : "", "ok 7\n";
   $procb->transfer ($main);
   print "not ok 8\n";
   die;
}

$/ = 55;

print "ok 2\n";
$main->transfer ($proca);
print $/ != 55 ? "not " : "ok 4\n";
$main->transfer ($proca);
print $/ != 55 ? "not " : "ok 6\n";
$main->transfer ($procb);
print $/ != 55 ? "not " : "ok 8\n";

