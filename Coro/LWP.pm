=head1 NAME

Coro::LWP - make LWP non-blocking - as much as possible

=head1 SYNOPSIS

 use Coro::LWP; # afterwards LWP should not block

=head1 DESCRIPTION

This module tries to make L<LWP|LWP> non-blocking with respect to other
coroutines as much as possible, and with whatever means it takes.

LWP really tries very hard to be blocking, so this module had to be very
invasive and must be loaded very early to take the proper effect.

Here is what it currently does (future versions of LWP might require
different tricks):

=over 4

=item It loads Coro::Select, overwriting the perl C<select> builtin I<globally>.

This is necessary because LWP calls select quite often for timeouts and
who-knows-what.

Impact: everybody else uses this (slower) version of select, too. It should be quite
compatible to perls builtin select, though.

=item It overwrites Socket::inet_aton with Coro::Util::inet_aton.

This is necessary because LWP might try to resolve hostnames this way.

Impact: likely little, the two functions should be pretty equivalent.

=item It overwrites IO::Socket::INET::new with Coro::Socket::new

This is necessary because LWP does not always use select to see wether a
filehandle can be read/written without blocking.

Impact: Coro::Socket is not at all compatible to IO::Socket::INET. While
it duplicates some undocumented functionality required by LWP, it does not
have all the methods of IO::Socket::INET and might act quite differently
in practise. Every app that uses IO::Socket::INET now has to cope with
Coro::Socket.

=back

All this likely makes other libraries than just LWP not block, but thats
just a side effect you cannot rely on.

Increases parallelism is not supported by all libraries, some might cache
data globally.

=cut

package Coro::LWP;

use strict;

use Coro::Select;
use Coro::Util;
use Coro::Socket;

use Socket;
use IO::Socket::INET;

*Socket::inet_aton = \&Coro::Util::inet_aton;

*IO::Socket::INET::new = sub {
   new Coro::Socket forward_class => @_;
};

=cut

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut


