BEGIN { $| = 1; print "1..8\n"; }
END {print "not ok 1\n" unless $loaded;}
use Coro::State;
$loaded = 1;
print "ok 1\n";

my $main  = new Coro::State;
my $proc  = new Coro::State \&a;
my $proc2 = new Coro::State \&b;

sub a {
   $/ = 77;
   print "ok 3\n";
   $proc->transfer ($main);
   print $/ == 77 ? "" : "not ", "ok 5\n";
   $proc->transfer ($main);
   print "not ok 6\n";
   die;
}

sub b {
   print $/ != 55 ? "not " : "", "ok 7\n";
   $proc2->transfer ($main);
   print "not ok 8\n";
   die;
}

$proc2->save (0);

$/ = 55;

print "ok 2\n";
$main->transfer ($proc);
print $/ != 55 ? "not " : "ok 4\n";
$main->transfer ($proc);
print $/ != 55 ? "not " : "ok 6\n";
$main->transfer ($proc2);
print $/ != 55 ? "not " : "ok 8\n";

