$|=1;
print "1..18\n";

use Coro;
use Coro::Cont;

$test = 1;

sub a1 : Coro {
   my $cont = csub {
      cede;
      yield $_*2;
      cede;
      yield $_*3;
   };
   my @arr = map &$cont, 1,2,3,4,5,6;
   for(2,6,6,12,10,18) {
      print (((shift @arr == $_) ? "ok " : "not ok "), $test++, "\n");
   }
   $done++;
   cede while 1;
}

sub a2 : Coro {
   my $cont = csub {
      cede;
      yield $_*20;
      cede;
      yield $_*30;
   };
   my @arr = map &$cont, 1,2,3,4,5,6;
   for(20,60,60,120,100,180) {
      print (((shift @arr == $_) ? "ok " : "not ok "), $test++, "\n");
   }
   $done++;
   cede while 1;
}

print "ok ", $test++, "\n";

$done = 0;

cede while $done < 2;

sub cont : Cont {
   yield 2*shift;
   yield 3*shift;
}

print cont(3) ==  6 ? "ok " : "not ok ", $test++, "\n";
print cont(4) == 12 ? "ok " : "not ok ", $test++, "\n";
print cont(5) == 10 ? "ok " : "not ok ", $test++, "\n";
print cont(6) == 18 ? "ok " : "not ok ", $test++, "\n";
print cont(7) == 14 ? "ok " : "not ok ", $test++, "\n";




