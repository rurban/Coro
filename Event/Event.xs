#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "CoroAPI.h"

MODULE = Coro::Event                PACKAGE = Coro::Event

BOOT:
{
        I_EVENT_API("Coro::Event");
	I_CORO_API ("Coro::Event");
}
