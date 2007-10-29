#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <assert.h>
#include <string.h>

#include "EVAPI.h"
#include "../Coro/CoroAPI.h"

static void
once_cb (int fd, short revents, void *arg)
{
  AV *av = (AV *)arg; /* @_ */
  av_push (av, newSViv (revents));
  CORO_READY (AvARRAY (av)[0]);
  SvREFCNT_dec (av);
}

#define ONCE_INIT  AV *av = GvAV (PL_defgv);
#define ONCE_CBARG once_cb, SvREFCNT_inc (av)
#define ONCE_DONE  av_clear (av); av_push (av, SvREFCNT_inc (CORO_CURRENT));

MODULE = Coro::EV                PACKAGE = Coro::EV

PROTOTYPES: ENABLE

BOOT:
{
        I_EV_API ("Coro::EV");
	I_CORO_API ("Coro::Event");
}

void
_timed_io_once (...)
	CODE:
{
	ONCE_INIT;
        assert (AvFILLp (av) >= 1);
        GEVAPI->once (
                              SvIV (AvARRAY (av)[0]),
                              SvIV (AvARRAY (av)[1]),
          AvFILLp (av) >= 2 ? SvNV (AvARRAY (av)[2]) : 0.,
          ONCE_CBARG
        );
        ONCE_DONE;
}

void
_timer_once (...)
	CODE:
{
	ONCE_INIT;
        NV after = SvNV (AvARRAY (av)[0]);
        GEVAPI->once (
          -1,
          EV_TIMEOUT,
          after > 0. ? after : 1e-30,
          ONCE_CBARG
        );
        ONCE_DONE;
}

void
loop ()
	CODE:
        while (1)
          {
            while (CORO_NREADY)
              CORO_CEDE_NOTSELF;

            GEVAPI->loop (EVLOOP_ONCE);
          }


