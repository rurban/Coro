#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <string.h>

#include "EventAPI.h"
#include "../Coro/CoroAPI.h"

#define CD_CORO	0
#define CD_TYPE	1
#define CD_OK	2
#define CD_GOT	3 /* hardcoded in Coro::Event, Coro::Handle */
#define CD_MAX	3
/* no support for hits and prio so far. */

#define EV_CLASS "Coro::Event"

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
  AV *priv = (AV *)SvRV ((SV *)pe->ext_data);
  IV type = SvIV (*av_fetch (priv, CD_TYPE, 1));
  SV *cd_coro = *av_fetch (priv, CD_CORO, 1);

  if (type == 1)
    av_store (priv, CD_GOT, newSViv (((pe_ioevent *)pe)->got));

  if (SvROK (cd_coro))
    {
      CORO_READY (cd_coro);
      av_store (priv, CD_CORO, &PL_sv_undef);
      NEED_SCHEDULE;
    }
  else
    {
      av_store (priv, CD_OK, &PL_sv_yes);
      GEventAPI->stop (pe->up, 0);
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
        SV *rv = newRV_noinc ((SV *)priv);

        av_extend (priv, CD_MAX);
        av_store (priv, CD_TYPE, newSViv (type));

        w->callback = coro_std_cb;
        w->ext_data = rv;

        hv_store ((HV *)SvRV (self),
                  EV_CLASS, strlen (EV_CLASS),
                  rv, 0);

void
_next(self)
	SV *	self
        CODE:
        pe_watcher *w = GEventAPI->sv_2watcher (self);
        AV *priv = (AV *)SvRV ((SV *)w->ext_data);

        if (SvOK (*av_fetch (priv, CD_CORO, 1)))
          croak ("only one coroutine can wait for an event");

        if (!w->running)
          GEventAPI->start (w, 1);

        if (*av_fetch (priv, CD_OK, 1) == &PL_sv_yes)
          {
            av_store (priv, CD_OK, &PL_sv_no);
            XSRETURN_NO;
          }
        else 
          {
            av_store (priv, CD_CORO, SvREFCNT_inc (CORO_CURRENT));
            XSRETURN_YES;
          }

