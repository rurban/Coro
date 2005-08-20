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

/* perl-related */
#define TRANSFER_SAVE_DEFAV	0x00000001 /* @_ */
#define TRANSFER_SAVE_DEFSV	0x00000002 /* $_ */
#define TRANSFER_SAVE_ERRSV	0x00000004 /* $@ */
/* c-related */
#define TRANSFER_SAVE_CCTXT	0x00000100
#ifdef CORO_LAZY_STACK
# define TRANSFER_LAZY_STACK	0x00000200
#else
# define TRANSFER_LAZY_STACK	0x00000000
#endif

#define TRANSFER_SAVE_ALL	(TRANSFER_SAVE_DEFAV|TRANSFER_SAVE_DEFSV \
                                |TRANSFER_SAVE_ERRSV|TRANSFER_SAVE_CCTXT)

struct coro; /* opaque */

struct CoroAPI {
  I32 ver;
#define CORO_API_VERSION 1

  /* internal */
  /*struct coro *(*sv_to_coro)(SV *arg, const char *funcname, const char *varname);*/

  /* public, state */
  void (*transfer)(pTHX_ SV *prev, SV *next, int flags);

  /* public, coro */
  void (*schedule)(void);
  void (*cede)(void);
  void (*ready)(SV *sv);
  int *nready;
  GV *current;
};

static struct CoroAPI *GCoroAPI;

#define CORO_TRANSFER(prev,next,flags) GCoroAPI->transfer(aTHX_ (prev), (next), (flags))
#define CORO_SCHEDULE            GCoroAPI->schedule ()
#define CORO_CEDE                GCoroAPI->cede ()
#define CORO_READY(coro)         GCoroAPI->ready (coro)
#define CORO_NREADY              (*GCoroAPI->nready)
#define CORO_CURRENT             SvRV(GvSV(GCoroAPI->current))

#define I_CORO_API(YourName)                                               \
STMT_START {                                                               \
  SV *sv = perl_get_sv("Coro::API",0);                                     \
  if (!sv) croak("Coro::API not found");                                   \
  GCoroAPI = (struct CoroAPI*) SvIV(sv);                                   \
  if (GCoroAPI->ver != CORO_API_VERSION) {                                 \
    croak("Coro::API version mismatch (%d != %d) -- please recompile %s",  \
          GCoroAPI->ver, CORO_API_VERSION, YourName);                      \
  }                                                                        \
} STMT_END

#endif

