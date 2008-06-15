#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stddef.h>
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

#define ONCE_INIT  AV *av = GvAV (PL_defgv)
#define ONCE_DONE  av_clear (av); av_push (av, newRV_inc (CORO_CURRENT))

static struct ev_prepare scheduler;
static struct ev_idle idler;
static int inhibit;

static void
idle_cb (EV_P_ ev_idle *w, int revents)
{
  ev_idle_stop (EV_A, w);
}

static void
prepare_cb (EV_P_ ev_prepare *w, int revents)
{
  static int incede;

  if (inhibit)
    return;

  ++incede;

  CORO_CEDE_NOTSELF;

  while (CORO_NREADY >= incede && CORO_CEDE)
    ;

  /* if still ready, then we have lower-priority coroutines.
   * poll anyways, but do not block.
   */
  if (CORO_NREADY >= incede)
    {
      if (!ev_is_active (&idler))
        ev_idle_start (EV_A, &idler);
    }
  else
    {
      if (ev_is_active (&idler))
        ev_idle_stop (EV_A, &idler);
    }

  --incede;
}

static void
readyhook (void)
{
  if (!ev_is_active (&idler))
    ev_idle_start (EV_DEFAULT_UC, &idler);
}

/*****************************************************************************/

typedef struct
{
  ev_io io;
  ev_timer tw;
  SV *done;
  SV *current;
} coro_dir;

typedef struct
{
  coro_dir r, w;
} coro_handle;


static int
handle_free (pTHX_ SV *sv, MAGIC *mg)
{
  coro_handle *data = (coro_handle *)mg->mg_ptr;
  mg->mg_ptr = 0;

  ev_io_stop    (EV_DEFAULT_UC, &data->r.io); ev_io_stop    (EV_DEFAULT_UC, &data->w.io);
  ev_timer_stop (EV_DEFAULT_UC, &data->r.tw); ev_timer_stop (EV_DEFAULT_UC, &data->w.tw);
  SvREFCNT_dec (data->r.done);                SvREFCNT_dec (data->w.done);
  SvREFCNT_dec (data->r.current);             SvREFCNT_dec (data->w.current);

  return 0;
}

static MGVTBL handle_vtbl = { 0,  0,  0,  0, handle_free };

static void
handle_cb (coro_dir *dir, int done)
{
  ev_io_stop    (EV_DEFAULT_UC, &dir->io);
  ev_timer_stop (EV_DEFAULT_UC, &dir->tw);

  sv_setiv (dir->done, done);
  SvREFCNT_dec (dir->done);
  dir->done = 0;
  CORO_READY (dir->current);
  SvREFCNT_dec (dir->current);
  dir->current = 0;
}

static void
handle_io_cb (EV_P_ ev_io *w, int revents)
{
  handle_cb ((coro_dir *)(((char *)w) - offsetof (coro_dir, io)), 1);
}

static void
handle_timer_cb (EV_P_ ev_timer *w, int revents)
{
  handle_cb ((coro_dir *)(((char *)w) - offsetof (coro_dir, tw)), 0);
}

/*****************************************************************************/

MODULE = Coro::EV                PACKAGE = Coro::EV

PROTOTYPES: ENABLE

BOOT:
{
        I_EV_API ("Coro::EV");
	I_CORO_API ("Coro::Event");

        EV_DEFAULT; /* make sure it is initialised */

        ev_prepare_init (&scheduler, prepare_cb);
        ev_set_priority (&scheduler, EV_MINPRI);
        ev_prepare_start (EV_DEFAULT_UC, &scheduler);
        ev_unref (EV_DEFAULT_UC);

        ev_idle_init (&idler, idle_cb);
        ev_set_priority (&idler, EV_MINPRI);

        CORO_READYHOOK = readyhook;
}

void
_loop_oneshot ()
	CODE:
{
        /* inhibit the prepare watcher, as we know we are the only
         * ready coroutine and we don't want it to start an idle watcher
         * just because of the fallback idle coro being of lower priority.
         */
        ++inhibit;

        /* same reasoning as above, make sure it is stopped */
        if (ev_is_active (&idler))
          ev_idle_stop (EV_DEFAULT_UC, &idler);

        ev_loop (EV_DEFAULT_UC, EVLOOP_ONESHOT);

        --inhibit;
}

void
_timed_io_once (...)
	CODE:
{
	ONCE_INIT;
        assert (AvFILLp (av) >= 1);
        ev_once (
          EV_DEFAULT_UC,
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
          EV_DEFAULT_UC,
          -1,
          0,
          after >= 0. ? after : 0.,
          once_cb,
          (void *)SvREFCNT_inc (av)
        );
        ONCE_DONE;
}

void
_readable_ev (SV *handle_sv, SV *done_sv)
	ALIAS:
        _writable_ev = 1
	CODE:
{
	AV *handle = (AV *)SvRV (handle_sv);
        SV *data_sv = AvARRAY (handle)[5];
        coro_handle *data;
        coro_dir *dir;
        assert (AvFILLp (handle) >= 7);

        if (!SvOK (data_sv))
          {
            int fno = sv_fileno (AvARRAY (handle)[0]);
            data_sv = AvARRAY (handle)[5] = NEWSV (0, sizeof (coro_handle));
            SvPOK_only (data_sv);
            SvREADONLY_on (data_sv);
            data = (coro_handle *)SvPVX (data_sv);
            memset (data, 0, sizeof (coro_handle));

            ev_io_init (&data->r.io, handle_io_cb, fno, EV_READ);
            ev_io_init (&data->w.io, handle_io_cb, fno, EV_WRITE);
            ev_init    (&data->r.tw, handle_timer_cb);
            ev_init    (&data->w.tw, handle_timer_cb);

            sv_magicext (data_sv, 0, PERL_MAGIC_ext, &handle_vtbl, (char *)data, 0);
          }
        else
          data = (coro_handle *)SvPVX (data_sv);

        dir = ix ? &data->w : &data->r;

        if (ev_is_active (&dir->io) || ev_is_active (&dir->tw))
          croak ("recursive invocation of readable_ev or writable_ev");

        dir->done = SvREFCNT_inc (done_sv);
        dir->current = SvREFCNT_inc (CORO_CURRENT);

        {
          SV *to = AvARRAY (handle)[2];

          if (SvOK (to))
            {
              ev_timer_set (&dir->tw, 0., SvNV (to));
              ev_timer_again (EV_DEFAULT_UC, &dir->tw);
            }
        }

        ev_io_start (EV_DEFAULT_UC, &dir->io);
}

