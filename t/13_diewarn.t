BEGIN { $| = 1; print "1..5\n"; }

use Coro;

print "ok 1\n";

async {
   local $SIG{__WARN__} = sub { print "ok 4\n" };
   {
      local $SIG{__WARN__} = sub { print "ok 2\n" };
      cede;
      warn "-";
   }
   cede;
   warn "-";
};

async {
   local $SIG{__WARN__} = sub { print "ok 5\n" };
   {
      local $SIG{__WARN__} = sub { print "ok 3\n" };
      cede;
      warn "-";
   }
   cede;
   warn "-";
};

cede;
cede;
cede;
cede;
