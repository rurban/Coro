
sub escape_uri {
   local $_ = shift;
   s/([()<>%&?,; ='"\x00-\x1f\x80-\xff])/sprintf "%%%02X", ord($1)/ge;
   $_;
}

sub escape_html($) {
   local $_ = shift;
   s/([<>&\x00-\x07\x09\x0b\x0d-\x1f\x7f-\x9f])/sprintf "&#%d;", ord($1)/ge;
   $_;
}

1;

