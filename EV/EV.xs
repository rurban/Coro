#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <assert.h>
#include <string.h>

#define EV_PROTOTYPES 0
#include "EVAPI.h"
#include "../Coro/CoroAPI.h"

static void
once_cb (int revents, void *arg)
{
  AV *av = (AV *)arg; /* @_ */
  av_push (av, newSViv (revents));
  CORO_READY (AvARRAY (av)[0]);
  SvREFCNT_dec (av);
}

#define ONCE_INIT  AV *av = GvAV (PL_defgv);
#define ONCE_DONE  av_clear (av); av_push (av, SvREFCNT_inc (CORO_CURRENT));

static struct ev_prepare scheduler;
static struct ev_idle idler;

static void
idle_cb (struct ev_idle *w, int revents)
{
  ev_idle_stop (w);
}

static void
prepare_cb (struct ev_prepare *w, int revents)
{
  static int incede;

  ++incede;

  CORO_CEDE_NOTSELF;

  while (CORO_NREADY >= incede && CORO_CEDE)
    ;

  /* if still ready, then we have lower-priority coroutines.
   * poll anyways, but do not block.
   */
  if (CORO_NREADY >= incede && !ev_is_active (&idler))
    ev_idle_start (&idler);

  --incede;
}

MODULE = Coro::EV                PACKAGE = Coro::EV

PROTOTYPES: ENABLE

BOOT:
{
        I_EV_API ("Coro::EV");
	I_CORO_API ("Coro::Event");

        ev_prepare_init (&scheduler, prepare_cb);
        ev_prepare_start (&scheduler);
        ev_unref ();

        ev_idle_init (&idler, idle_cb);
}

void
_timed_io_once (...)
	CODE:
{
	ONCE_INIT;
        assert (AvFILLp (av) >= 1);
        ev_once (
          sv_fileno (AvARRAY (av)[0]),
          SvIV (AvARRAY (av)[1]),
          AvFILLp (av) >= 2 && SvOK (AvARRAY (av)[2]) ? SvNV (AvARRAY (av)[2]) : -1.,
          once_cb,
          (void *)SvREFCNT_inc (av)
        );
        ONCE_DONE;
}

void
_timer_once (...)
	CODE:
{
	ONCE_INIT;
        NV after = SvNV (AvARRAY (av)[0]);
        ev_once (
          -1,
          0,
          after >= 0. ? after : 0.,
          once_cb,
          (void *)SvREFCNT_inc (av)
        );
        ONCE_DONE;
}



