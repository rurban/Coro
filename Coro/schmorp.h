#ifndef SCHMORP_PERL_H_
#define SCHMORP_PERL_H_

/* WARNING
 * This header file is a shared resource between many modules.
 */

/* useful stuff, used by schmorp mostly */

#include "patchlevel.h"

#define PERL_VERSION_ATLEAST(a,b,c)				\
  (PERL_REVISION > (a)						\
   || (PERL_REVISION == (a)					\
       && (PERL_VERSION > (b)					\
           || (PERL_VERSION == (b) && PERL_SUBVERSION >= (c)))))

#if !PERL_VERSION_ATLEAST (5,6,0)
# ifndef PL_ppaddr
#  define PL_ppaddr ppaddr
# endif
# ifndef call_sv
#  define call_sv perl_call_sv
# endif
# ifndef get_sv
#  define get_sv perl_get_sv
# endif
# ifndef get_cv
#  define get_cv perl_get_cv
# endif
# ifndef IS_PADGV
#  define IS_PADGV(v) 0
# endif
# ifndef IS_PADCONST
#  define IS_PADCONST(v) 0
# endif
#endif

/* 5.11 */
#ifndef CxHASARGS
# define CxHASARGS(cx) (cx)->blk_sub.hasargs
#endif

/* 5.10.0 */
#ifndef SvREFCNT_inc_NN
# define SvREFCNT_inc_NN(sv) SvREFCNT_inc (sv)
#endif

/* 5.8.8 */
#ifndef GV_NOTQUAL
# define GV_NOTQUAL 0
#endif
#ifndef newSV
# define newSV(l) NEWSV(0,l)
#endif
#ifndef CvISXSUB_on
# define CvISXSUB_on(cv) (void)cv
#endif
#ifndef CvISXSUB
# define CvISXSUB(cv) (CvXSUB (cv) ? TRUE : FALSE)
#endif
#ifndef Newx
# define Newx(ptr,nitems,type) New (0,ptr,nitems,type)
#endif

/* 5.8.7 */
#ifndef SvRV_set
# define SvRV_set(s,v) SvRV(s) = (v)
#endif

static int
s_signum (SV *sig)
{
#ifndef SIG_SIZE
  /* kudos to Slaven Rezic for the idea */
  static char sig_size [] = { SIG_NUM };
# define SIG_SIZE (sizeof (sig_size) + 1)
#endif
  dTHX;
  int signum;

  SvGETMAGIC (sig);

  for (signum = 1; signum < SIG_SIZE; ++signum)
    if (strEQ (SvPV_nolen (sig), PL_sig_name [signum]))
      return signum;

  signum = SvIV (sig);

  if (signum > 0 && signum < SIG_SIZE)
    return signum;

  return -1;
}

static int
s_signum_croak (SV *sig)
{
  int signum = s_signum (sig);

  if (signum < 0)
    {
      dTHX;
      croak ("%s: invalid signal name or number", SvPV_nolen (sig));
    }

  return signum;
}

static int
s_fileno (SV *fh, int wr)
{
  dTHX;
  SvGETMAGIC (fh);

  if (SvROK (fh))
    {
      fh = SvRV (fh);
      SvGETMAGIC (fh);
    }

  if (SvTYPE (fh) == SVt_PVGV)
    return PerlIO_fileno (wr ? IoOFP (sv_2io (fh)) : IoIFP (sv_2io (fh)));

  if (SvOK (fh) && (SvIV (fh) >= 0) && (SvIV (fh) < 0x7fffffffL))
    return SvIV (fh);

  return -1;
}

static int
s_fileno_croak (SV *fh, int wr)
{
  int fd = s_fileno (fh, wr);

  if (fd < 0)
    {
      dTHX;
      croak ("%s: illegal fh argument, either not an OS file or read/write mode mismatch", SvPV_nolen (fh));
    }

  return fd;
}

static SV *
s_get_cv (SV *cb_sv)
{
  dTHX;
  HV *st;
  GV *gvp;

  return (SV *)sv_2cv (cb_sv, &st, &gvp, 0);
}

static SV *
s_get_cv_croak (SV *cb_sv)
{
  SV *cv = s_get_cv (cb_sv);

  if (!cv)
    {
      dTHX;
      croak ("%s: callback must be a CODE reference or another callable object", SvPV_nolen (cb_sv));
    }

  return cv;
}

/*****************************************************************************/
/* gensub: simple closure generation utility */

#define S_GENSUB_ARG CvXSUBANY (cv).any_ptr

/* create a closure from XS, returns a code reference */
/* the arg can be accessed via GENSUB_ARG from the callback */
/* the callback must use dXSARGS/XSRETURN */
static SV *
s_gensub (pTHX_ void (*xsub)(pTHX_ CV *), void *arg)
{
  CV *cv = (CV *)newSV (0);

  sv_upgrade ((SV *)cv, SVt_PVCV);

  CvANON_on (cv);
  CvISXSUB_on (cv);
  CvXSUB (cv) = xsub;
  S_GENSUB_ARG = arg;

  return newRV_noinc ((SV *)cv);
}

#endif

