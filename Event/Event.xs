#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <assert.h>
#include <string.h>

#include "EventAPI.h"
#include "../Coro/CoroAPI.h"

#define CD_CORO	0
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
  SV **cd_coro;

  SvIV_set (AvARRAY (priv)[CD_HITS], pe->hits);

  if (type == 1)
    SvIV_set (AvARRAY (priv)[CD_GOT], ((pe_ioevent *)pe)->got);

  GEventAPI->stop (pe->up, 0);

  AvARRAY (priv)[CD_OK] = &PL_sv_yes;

  cd_coro = &AvARRAY(priv)[CD_CORO];
  if (*cd_coro != &PL_sv_undef)
    {
      AvARRAY (priv)[CD_OK] = &PL_sv_yes;
      CORO_READY (*cd_coro);
      SvREFCNT_dec (*cd_coro);
      *cd_coro = &PL_sv_undef;
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

          av_extend (priv, CD_MAX);
          AvARRAY (priv)[CD_CORO] = &PL_sv_undef;
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

        if (!w->running)
          {
            SvIV_set (AvARRAY (priv)[CD_GOT],  0);
            SvIV_set (AvARRAY (priv)[CD_HITS], 0);

            GEventAPI->start (w, 1);
          }

        if (AvARRAY (priv)[CD_CORO] == &PL_sv_undef)
          AvARRAY (priv)[CD_CORO] = SvREFCNT_inc (CORO_CURRENT);
        else if (AvARRAY (priv)[CD_CORO] != CORO_CURRENT)
          croak ("Coro::Event::next can only be called from a single coroutine at a time, caught");

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

