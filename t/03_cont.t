$|=1;
print "1..13\n";

use Coro;
use Coro::Cont;

$test = 1;

sub a1 : Coro {
   my $cont = cont {
      { local $_; yield };
      result $_*2;
      { local $_; yield };
      result $_*3;
   };
   my @arr = map &$cont, 1,2,3,4,5,6;
   for(2,6,6,12,10,18) {
      print (((shift @arr == $_) ? "ok " : "not ok "), $test++, "\n");
   }
   $done++;
   yield while 1;
}

sub a2 : Coro {
   my $cont = cont {
      { local $_; yield };
      result $_*20;
      { local $_; yield };
      result $_*30;
   };
   my @arr = map &$cont, 1,2,3,4,5,6;
   for(20,60,60,120,100,180) {
      print (((shift @arr == $_) ? "ok " : "not ok "), $test++, "\n");
   }
   $done++;
   yield while 1;
}

print "ok ", $test++, "\n";

$done = 0;

yield while $done < 2;
