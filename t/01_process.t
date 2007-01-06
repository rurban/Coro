$|=1;
print "1..9\n";

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
   print "not ok 8\n";#d#
};

print $c1->ready ? "not " : "", "ok 4\n";

cede;

print "ok 6\n";

$c1->on_destroy (sub {
   print "ok 7\n";
});

$c1->cancel;

print "ok 8\n";

cede; cede;

print "ok 9\n";

