
use BerkeleyDB;

if (defined $DB_HOME) {

   mkdir $DB_HOME, 0700;

   $db_env = new BerkeleyDB::Env
                 -Home => $DB_HOME,
                 -Cachesize => 1_000_000,
                 -ErrFile => "/proc/self/fd/2",
                 -ErrPrefix => "DATABASE",
                 -Verbose => 1,
                 -Flags => DB_CREATE|DB_RECOVER|DB_INIT_MPOOL|DB_INIT_TXN
                    or die "unable to create database home $DB_HOME";
}

1;
