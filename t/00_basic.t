BEGIN { $| = 1; print "1..6\n"; }
END {print "not ok 1\n" unless $loaded;}
use Coro;
$loaded = 1;
print "ok 1\n";

my $main = $Coro::main;
my $proc = new Coro \&a;

sub a {
   print "ok 3\n";
   $main->resume;
   print "ok 5\n";
   $main;
}

print "ok 2\n";
$proc->resume;
print "ok 4\n";
$proc->resume;
print "ok 6\n";

