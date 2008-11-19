$|=1;
print "1..7\n";

no warnings;
use Coro;
use Coro::Signal;

{
   my $sig = new Coro::Signal;

   $as1 = async {
      my $g = $sig->wait;
      print "ok 2\n";
   };    

   $as2 = async {
      my $g = $sig->wait;
      print "ok 4\n";
   };    

   cede;

   $sig->send;

   $as3 = async {
      my $g = $sig->wait;
      print "ok 5\n";
   };    

   $sig->send;

   $as4 = async {
      my $g = $sig->wait;
      print "ok 6\n";
   };    

   $sig->send;

   print +(Coro::Semaphore::count $sig) == 1 ? "" : "not ", "ok 1\n";

   cede;

   print +(Coro::Semaphore::count $sig) == 0 ? "" : "not ", "ok 3\n";

   $sig->send;
   cede;

   print +(Coro::Semaphore::count $sig) == 0 ? "" : "not ", "ok 5\n";

   $sig->broadcast;
   print +(Coro::Semaphore::count $sig) == 0 ? "" : "not ", "ok 6\n";
   cede;

   print +(Coro::Semaphore::count $sig) == 0 ? "" : "not ", "ok 7\n";
}

