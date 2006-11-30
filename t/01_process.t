$|=1;
print "1..6\n";

use Coro;

sub p1 : Coro {
   print "ok 2\n";
}

print "ok 1\n";
cede;
print "ok 3\n";

my $c1 = async {
   print "ok 5\n";
   cede;
};

print $c1->ready ? "not " : "", "ok 4\n";

cede;

print "ok 6\n";

