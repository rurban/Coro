#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <assert.h>
#include <string.h>

#include "EventAPI.h"
#include "../Coro/CoroAPI.h"

#define CD_WAIT	0 /* wait queue */
#define CD_TYPE	1
#define CD_OK	2

#define CD_HITS	4 /* hardcoded in Coro::Event */
#define CD_GOT	5 /* hardcoded in Coro::Event, Coro::Handle */
#define CD_MAX	5

static void
coro_std_cb (pe_event *pe)
{
  AV *priv = (AV *)pe->ext_data;
  IV type = SvIV (AvARRAY (priv)[CD_TYPE]);
  AV *cd_wait;
  SV *coro;

  SvIV_set (AvARRAY (priv)[CD_HITS], pe->hits);
  SvIV_set (AvARRAY (priv)[CD_GOT], type ? ((pe_ioevent *)pe)->got : 0);

  AvARRAY (priv)[CD_OK] = &PL_sv_yes;

  cd_wait = (AV *)AvARRAY(priv)[CD_WAIT];
  if ((coro = av_shift (cd_wait)))
    {
      if (av_len (cd_wait) < 0)
        GEventAPI->stop (pe->up, 0);

      CORO_READY (coro);
      SvREFCNT_dec (coro);
    }
}

static void
asynccheck_hook (void *data)
{
  /* ceding from C means allocating a stack, but we assume this is a rare case */
  while (CORO_NREADY)
    CORO_CEDE;
}

MODULE = Coro::Event                PACKAGE = Coro::Event

PROTOTYPES: ENABLE

BOOT:
{
        I_EVENT_API ("Coro::Event");
	I_CORO_API ("Coro::Event");

        GEventAPI->add_hook ("asynccheck", (void *)asynccheck_hook, 0);
}

void
_install_std_cb (SV *self, int type)
        CODE:
{
        pe_watcher *w = GEventAPI->sv_2watcher (self);

        if (w->callback)
          croak ("Coro::Event watchers must not have a callback (see Coro::Event), caught");

        {
          AV *priv = newAV ();
          SV *rv = newRV_noinc ((SV *)priv);

          av_fill (priv, CD_MAX);
          AvARRAY (priv)[CD_WAIT] = (SV *)newAV (); /* badbad */
          AvARRAY (priv)[CD_TYPE] = newSViv (type);
          AvARRAY (priv)[CD_OK  ] = &PL_sv_no;
          AvARRAY (priv)[CD_HITS] = newSViv (0);
          AvARRAY (priv)[CD_GOT ] = newSViv (0);
          SvREADONLY_on (priv);

          w->callback = coro_std_cb;
          w->ext_data = priv;

          /* make sure Event does not use PERL_MAGIC_uvar, which */
          /* we abuse for non-uvar purposes. */
          sv_magicext (SvRV (self), rv, PERL_MAGIC_uvar, 0, 0, 0);
        }
}

void
_next (SV *self)
        CODE:
{
        pe_watcher *w = GEventAPI->sv_2watcher (self);
        AV *priv = (AV *)w->ext_data;

        if (AvARRAY (priv)[CD_OK] == &PL_sv_yes)
          {
            AvARRAY (priv)[CD_OK] = &PL_sv_no;
            XSRETURN_NO; /* got an event */
          }

        av_push ((AV *)AvARRAY (priv)[CD_WAIT], SvREFCNT_inc (CORO_CURRENT));

        if (!w->running)
          GEventAPI->start (w, 1);

        XSRETURN_YES; /* schedule */
}

SV *
_event (SV *self)
	CODE:
{
        if (GIMME_V == G_VOID)
          XSRETURN_EMPTY;

        {
          pe_watcher *w = GEventAPI->sv_2watcher (self);
          AV *priv = (AV *)w->ext_data;

          RETVAL = newRV_inc ((SV *)priv);
        }
}
	OUTPUT:
        RETVAL

