#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <string.h>

#include "EventAPI.h"
#include "../Coro/CoroAPI.h"

#define CD_CORO	0
#define CD_TYPE	1
#define CD_W	2
#define CD_GOT	3
#define CD_MAX	3
/* no support for hits and prio so far. */

#define EV_CLASS "Coro::Event::Ev"

static HV *ev_stash;
static pe_idle *scheduler;
static int do_schedule;

#define NEED_SCHEDULE if (!do_schedule)					\
                        {						\
 		          do_schedule = 1;				\
		          GEventAPI->now ((pe_watcher *)scheduler);	\
                        }
static void
coro_std_cb(pe_event *pe)
{
  AV *av = (AV *)SvRV ((SV *)pe->ext_data);
  IV type = SvIV (*av_fetch (av, CD_TYPE, 1));
  SV *cd_coro = *av_fetch (av, CD_CORO, 1);

  av_store (av, CD_W, SvREFCNT_inc (pe->up->mysv));

  if (type == 1)
    av_store (av, CD_GOT, newSViv (((pe_ioevent *)pe)->got));

  GEventAPI->stop (pe->up, 0);

  if (SvROK (cd_coro))
    {
      CORO_READY (cd_coro);
      NEED_SCHEDULE;
    }
}

static void
scheduler_cb(pe_event *pe)
{
  while (CORO_NREADY)
    CORO_CEDE;

  do_schedule = 0;
}

MODULE = Coro::Event                PACKAGE = Coro::Event

PROTOTYPES: ENABLE

BOOT:
{
        I_EVENT_API("Coro::Event");
	I_CORO_API ("Coro::Event");

	ev_stash = gv_stashpv (EV_CLASS, TRUE);

        /* create a fake idle handler (we only ever call now) */
        scheduler = GEventAPI->new_idle (0, 0);
        scheduler->base.callback = scheduler_cb;
        scheduler->min_interval = newSVnv (0);
        scheduler->max_interval = newSVnv (0);
        GEventAPI->stop ((pe_watcher *)scheduler, 0);
}

void
_install_std_cb(self,type)
	SV *	self
        int	type
        CODE:
        pe_watcher *w = GEventAPI->sv_2watcher (self);
        AV *priv = newAV ();
        SV *rv;

        av_extend (priv, CD_MAX);
        av_store (priv, CD_TYPE, newSViv (type));

        rv = sv_bless (newRV_noinc ((SV *)priv), ev_stash);

        hv_store ((HV *)SvRV (self),
                  EV_CLASS, strlen (EV_CLASS),
                  rv, 0);

        w->ext_data = rv;
        w->callback = coro_std_cb;

void
_next0(self)
	SV *	self
        CODE:
        pe_watcher *w = GEventAPI->sv_2watcher (self);
        AV *priv = (AV *)SvRV ((SV *)w->ext_data);

        GEventAPI->start (w, 1);

        if (SvROK (*av_fetch (priv, CD_CORO, 1)))
          croak ("only one coroutine can wait for an event");

        av_store (priv, CD_CORO, SvREFCNT_inc (CORO_CURRENT));

SV *
_next1(self)
	SV *	self
        CODE:
        pe_watcher *w = GEventAPI->sv_2watcher (self);
        AV *priv = (AV *)SvRV ((SV *)w->ext_data);

        av_store (priv, CD_CORO, &PL_sv_undef);

        RETVAL = SvREFCNT_inc ((SV *)w->ext_data);
	OUTPUT:
        RETVAL

