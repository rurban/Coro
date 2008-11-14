#ifndef CORO_API_H
#define CORO_API_H

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#ifndef pTHX_
# define pTHX_
# define aTHX_
# define pTHX
# define aTHX
#endif

/*struct coro;*/ /* opaque */

enum {
  CORO_SLF_SCHEDULE     = 3,
  CORO_SLF_CEDE         = 4,
  CORO_SLF_CEDE_NOTSELF = 5
};

struct CoroSLF
{
  int (*prepare) (pTHX_ SV **arg, int items); /* returns CORO_SLF_* */
  int (*check) (pTHX); /* returns repeat-flag */
};

/* private structure, always use the provided macros below */
struct CoroAPI
{
  I32 ver;
  I32 rev;
#define CORO_API_VERSION 7
#define CORO_API_REVISION 0

  /* Coro */
  int nready;
  SV *current;
  void (*readyhook) (void);

  void (*schedule) (pTHX);
  int (*cede) (pTHX);
  int (*cede_notself) (pTHX);
  int (*ready) (pTHX_ SV *coro_sv);
  int (*is_ready) (pTHX_ SV *coro_sv);

  /* Coro::State */
  void (*transfer) (pTHX_ SV *prev_sv, SV *next_sv); /* Coro::State */
  void (*execute_slf) (pTHX_ CV *cv, const struct CoroSLF *slf, SV **arg, int nitems);

};

static struct CoroAPI *GCoroAPI;

/* public API macros */
#define CORO_TRANSFER(prev,next) GCoroAPI->transfer (aTHX_ (prev), (next))
#define CORO_SCHEDULE            GCoroAPI->schedule (aTHX)
#define CORO_CEDE                GCoroAPI->cede (aTHX)
#define CORO_CEDE_NOTSELF        GCoroAPI->cede_notself (aTHX)
#define CORO_READY(coro)         GCoroAPI->ready (aTHX_ coro)
#define CORO_IS_READY(coro)      GCoroAPI->is_ready (coro)
#define CORO_NREADY              GCoroAPI->nready
#define CORO_CURRENT             SvRV (GCoroAPI->current)
#define CORO_READYHOOK           GCoroAPI->readyhook

#define CORO_EXECUTE_SLF(cv,slf,arg,nitems) GCoroAPI->execute_slf (aTHX_ (cv), &(slf), (arg), (nitems))
#define CORO_EXECUTE_SLF_XS(slf) CORO_EXECUTE_SLF (cv, (slf), &ST (0), nitems)

#define I_CORO_API(YourName)                                                             \
STMT_START {                                                                             \
  SV *sv = perl_get_sv ("Coro::API", 0);                                                 \
  if (!sv) croak ("Coro::API not found");                                                \
  GCoroAPI = (struct CoroAPI*) SvIV (sv);                                                \
  if (GCoroAPI->ver != CORO_API_VERSION                                                  \
      || GCoroAPI->rev < CORO_API_REVISION)                                              \
    croak ("Coro::API version mismatch (%d.%d vs. %d.%d) -- please recompile %s",        \
           GCoroAPI->ver, GCoroAPI->rev, CORO_API_VERSION, CORO_API_REVISION, YourName); \
} STMT_END

#endif

