$|=1;
print "1..5\n";

use Coro;

async {
   my $t = eval "2";
   print "ok $t\n";
   cede;
   print defined eval "1/0" ? "not ok" : "ok", " 4\n";
};

async {
   my $t = eval "3";
   print "ok $t\n";
   cede;
   print defined eval "die" ? "not ok" : "ok", " 5\n";
};

print "ok 1\n";
cede;
cede;

