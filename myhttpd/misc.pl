
sub escape_uri {
   local $_ = shift;
   s/([()<>%&?,; ='"\x00-\x1f\x80-\xff])/sprintf "%%%02X", ord($1)/ge;
   $_;
}

1;

