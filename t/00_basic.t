BEGIN { $| = 1; print "1..6\n"; }
END {print "not ok 1\n" unless $loaded;}
use Coro;
$loaded = 1;
print "ok 1\n";

my $main = new Coro;
my $proc = new Coro \&a;

sub a {
   print "ok 3\n";
   $proc->transfer($main);
   print "ok 5\n";
   $proc->transfer($main);
   die;
}

print "ok 2\n";
$main->transfer($proc);
print "ok 4\n";
$main->transfer($proc);
print "ok 6\n";

