use PApp::SQL;

$PApp::SQL::DBH = DBI->connect("DBI:mysql:mymap")
   or die "database: $!";

$CR = "\015";
$CRLF = "\015\012";

$F_D        = 0x01;
$F_deleted  = 0x02;
$F_flagged  = 0x04;
$F_answered = 0x08;
$F_seen     = 0x10;
$F_draft    = 0x20;

sub find_uid {
   sql_fetch "select id from user where name = ?", $_[0];
}

sub find_bid {
   sql_fetch "select id from box where uid = ? and name = ?", $_[0], $_[1];
}

my $skip_from = qr{^pcg\@goof.com$}i;
my $skip_to   = qr{(\.laendle|plan9\.de|schmorp\.de)$}i;

sub _raddr {
   $_raddr{$_[0]} ||= eval { (parse Mail::Address $_[0])[0]->address };
}

sub deliver_mail {
   my ($bid, $env_from, $env_to, $date, $flags, $head, $body) = @_;

   sql_exec "lock tables box write, msg write";
   unless (sql_exists "msg where bid = ? and env_from = ? and env_to = ? and ntime = ? and header = ? and body = ?",
                      $bid, $env_from, $env_to,$date, $head, $body) {
      sql_exec "insert into msg (bid, env_from, env_to, ntime, flags, header, body)
                       values (?,?,?,?,?,?,?)",
               $bid, $env_from, $env_to, $date, $flags, $head, $body;
   }
   sql_exec "unlock tables";
}

# import Mail::Message object into the given folder
sub import_mailmsg {
   my ($bid, $msg) = @_;

   my $body = join "", @{$msg->body};
   $msg = $msg->head;
   $msg->unfold;

   my ($from, $to, $date);

   if ($from = $msg->get("Mail-From")) {
      $msg->delete("Mail-From");
      ($from, $date) = split /\s+/, $from, 2;
   }

   undef $from if $from =~ $skip_from;

   $from ||= $msg->get("Sender") || $msg->get("From");

   $from = _raddr $from;

   $to = _raddr $msg->get("To");
   for (my $idx = 0; $idx < 29; $idx++) {
      my $rcvd = extract Mail::Field "Received", $msg, $idx
         or last;
      $rcvd = $rcvd->parse_tree;
      $date ||= $rcvd->{date_time}{date_time};
      my $xto = _raddr $rcvd->{for}{for}
         or next;
      $to = $xto;
      last unless $to =~ $skip_to;
   }

   my $status = $msg->get("Status"); $msg->delete("Status");

   $date = str2time($date);

   my @flags;
   push @flags, "seen"     if $status =~ /O/i;
   push @flags, "deleted"  if $status =~ /D/i;
   push @flags, "answered" if $status =~ /R/i;
   push @flags, "flagged"  if $status =~ /!/i;
   push @flags, "recent"   if !$status;

   $msg->delete("Content-Length");

   my $head = $msg->as_string;

   for ($body, $head) {
      s/\n/$CRLF/o;
   }
   
   deliver_mail ($bid, $from, $to, $date, (join ",", @flags), $head, $body);
}

sub flags2bitmask {
   my $mask = 0;

   for (@_) {
      $mask |= $F_D        if /^\\D$/i;
      $mask |= $F_deleted  if /^\\deleted$/i;
      $mask |= $F_flagged  if /^\\flagged$/i;
      $mask |= $F_answered if /^\\answered$/i;
      $mask |= $F_seen     if /^\\seen$/i;
      $mask |= $F_draft    if /^\\draft$/i;
   }

   $mask;
}
