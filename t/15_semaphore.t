$|=1;
print "1..1\n";

use Coro;
use Coro::Semaphore;

my $sem = new Coro::Semaphore 2;

my $rand = 0;

sub xrand {
   $rand = ($rand * 121 + 2121) % 212121;
   $rand / 212120
}

my $counter;

$_->join for
   map {
      async {
         my $current = $Coro::current;
         for (1..100) {
            cede if 0.2 > xrand;
            Coro::async_pool { $current->ready } if 0.2 > xrand;
            $counter += $sem->count;
            my $guard = $sem->guard;
            cede; cede; cede; cede;
         }
      }
   } 1..15
;

print $counter == 750 ? "" : "not ", "ok 1 # $counter\n"

