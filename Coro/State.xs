#include "libcoro/coro.c"

#define PERL_NO_GET_CONTEXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "patchlevel.h"

#include <stdio.h>
#include <errno.h>
#include <assert.h>

#ifdef HAVE_MMAP
# include <unistd.h>
# include <sys/mman.h>
# ifndef MAP_ANONYMOUS
#  ifdef MAP_ANON
#   define MAP_ANONYMOUS MAP_ANON
#  else
#   undef HAVE_MMAP
#  endif
# endif
# include <limits.h>
# ifndef PAGESIZE
#  define PAGESIZE pagesize
#  define BOOT_PAGESIZE pagesize = sysconf (_SC_PAGESIZE)
static long pagesize;
# else
#  define BOOT_PAGESIZE (void)0
# endif
#else
# define PAGESIZE 0
# define BOOT_PAGESIZE (void)0
#endif

#if CORO_USE_VALGRIND
# include <valgrind/valgrind.h>
# define REGISTER_STACK(cctx,start,end) (cctx)->valgrind_id = VALGRIND_STACK_REGISTER ((start), (end))
#else
# define REGISTER_STACK(cctx,start,end)
#endif

/* the maximum number of idle cctx that will be pooled */
#define MAX_IDLE_CCTX 8

#define PERL_VERSION_ATLEAST(a,b,c)				\
  (PERL_REVISION > (a)						\
   || (PERL_REVISION == (a)					\
       && (PERL_VERSION > (b)					\
           || (PERL_VERSION == (b) && PERLSUBVERSION >= (c)))))

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

/* 5.8.7 */
#ifndef SvRV_set
# define SvRV_set(s,v) SvRV(s) = (v)
#endif

#if !__i386 && !__x86_64 && !__powerpc && !__m68k && !__alpha && !__mips && !__sparc64
# undef CORO_STACKGUARD
#endif

#ifndef CORO_STACKGUARD
# define CORO_STACKGUARD 0
#endif

/* prefer perl internal functions over our own? */
#ifndef CORO_PREFER_PERL_FUNCTIONS
# define CORO_PREFER_PERL_FUNCTIONS 0
#endif

/* The next macros try to return the current stack pointer, in an as
 * portable way as possible. */
#define dSTACKLEVEL volatile char stacklevel
#define STACKLEVEL ((void *)&stacklevel)

#define IN_DESTRUCT (PL_main_cv == Nullcv)

#if __GNUC__ >= 3
# define attribute(x) __attribute__(x)
# define BARRIER __asm__ __volatile__ ("" : : : "memory")
#else
# define attribute(x)
# define BARRIER
#endif

#define NOINLINE attribute ((noinline))

#include "CoroAPI.h"

#ifdef USE_ITHREADS
static perl_mutex coro_mutex;
# define LOCK   do { MUTEX_LOCK   (&coro_mutex); } while (0)
# define UNLOCK do { MUTEX_UNLOCK (&coro_mutex); } while (0)
#else
# define LOCK   (void)0
# define UNLOCK (void)0
#endif

/* helper storage struct for Coro::AIO */
struct io_state
{
  int errorno;
  I32 laststype;
  int laststatval;
  Stat_t statcache;
};

static size_t coro_stacksize = CORO_STACKSIZE;
static struct CoroAPI coroapi;
static AV *main_mainstack; /* used to differentiate between $main and others */
static JMPENV *main_top_env;
static HV *coro_state_stash, *coro_stash;
static SV *coro_mortal; /* will be freed after next transfer */

static GV *irsgv; /* $/ */

/* async_pool helper stuff */
static SV *sv_pool_rss;
static SV *sv_pool_size;
static AV *av_async_pool;

static struct coro_cctx *cctx_first;
static int cctx_count, cctx_idle;

enum {
  CC_MAPPED     = 0x01,
  CC_NOREUSE    = 0x02, /* throw this away after tracing */
  CC_TRACE      = 0x04,
  CC_TRACE_SUB  = 0x08, /* trace sub calls */
  CC_TRACE_LINE = 0x10, /* trace each statement */
  CC_TRACE_ALL  = CC_TRACE_SUB | CC_TRACE_LINE,
};

/* this is a structure representing a c-level coroutine */
typedef struct coro_cctx {
  struct coro_cctx *next;

  /* the stack */
  void *sptr;
  size_t ssize;

  /* cpu state */
  void *idle_sp;   /* sp of top-level transfer/schedule/cede call */
  JMPENV *idle_te; /* same as idle_sp, but for top_env, TODO: remove once stable */
  JMPENV *top_env;
  coro_context cctx;

#if CORO_USE_VALGRIND
  int valgrind_id;
#endif
  unsigned char flags;
} coro_cctx;

enum {
  CF_RUNNING   = 0x0001, /* coroutine is running */
  CF_READY     = 0x0002, /* coroutine is ready */
  CF_NEW       = 0x0004, /* has never been switched to */
  CF_DESTROYED = 0x0008, /* coroutine data has been freed */
};

/* this is a structure representing a perl-level coroutine */
struct coro {
  /* the c coroutine allocated to this perl coroutine, if any */
  coro_cctx *cctx;

  /* data associated with this coroutine (initial args) */
  AV *args;
  int refcnt;
  int flags; /* CF_ flags */

  /* optionally saved, might be zero */
  AV *defav; /* @_ */
  SV *defsv; /* $_ */
  SV *errsv; /* $@ */
  SV *deffh; /* default filehandle */
  SV *irssv; /* $/ */
  SV *irssv_sv; /* real $/ cache */
  
#define VAR(name,type) type name;
# include "state.h"
#undef VAR

  /* statistics */
  int usecount; /* number of transfers to this coro */

  /* coro process data */
  int prio;
  //SV *throw;

  /* async_pool */
  SV *saved_deffh;

  /* linked list */
  struct coro *next, *prev;
  HV *hv; /* the perl hash associated with this coro, if any */
};

typedef struct coro *Coro__State;
typedef struct coro *Coro__State_or_hashref;

/** Coro ********************************************************************/

#define PRIO_MAX     3
#define PRIO_HIGH    1
#define PRIO_NORMAL  0
#define PRIO_LOW    -1
#define PRIO_IDLE   -3
#define PRIO_MIN    -4

/* for Coro.pm */
static SV *coro_current;
static AV *coro_ready [PRIO_MAX-PRIO_MIN+1];
static int coro_nready;
static struct coro *coro_first;

/** lowlevel stuff **********************************************************/

static AV *
coro_clone_padlist (pTHX_ CV *cv)
{
  AV *padlist = CvPADLIST (cv);
  AV *newpadlist, *newpad;

  newpadlist = newAV ();
  AvREAL_off (newpadlist);
#if PERL_VERSION_ATLEAST (5,9,0)
  Perl_pad_push (aTHX_ padlist, AvFILLp (padlist) + 1);
#else
  Perl_pad_push (aTHX_ padlist, AvFILLp (padlist) + 1, 1);
#endif
  newpad = (AV *)AvARRAY (padlist)[AvFILLp (padlist)];
  --AvFILLp (padlist);

  av_store (newpadlist, 0, SvREFCNT_inc (*av_fetch (padlist, 0, FALSE)));
  av_store (newpadlist, 1, (SV *)newpad);

  return newpadlist;
}

static void
free_padlist (pTHX_ AV *padlist)
{
  /* may be during global destruction */
  if (SvREFCNT (padlist))
    {
      I32 i = AvFILLp (padlist);
      while (i >= 0)
        {
          SV **svp = av_fetch (padlist, i--, FALSE);
          if (svp)
            {
              SV *sv;
              while (&PL_sv_undef != (sv = av_pop ((AV *)*svp)))
                SvREFCNT_dec (sv);

              SvREFCNT_dec (*svp);
            }
        }

      SvREFCNT_dec ((SV*)padlist);
    }
}

static int
coro_cv_free (pTHX_ SV *sv, MAGIC *mg)
{
  AV *padlist;
  AV *av = (AV *)mg->mg_obj;

  /* casting is fun. */
  while (&PL_sv_undef != (SV *)(padlist = (AV *)av_pop (av)))
    free_padlist (aTHX_ padlist);

  SvREFCNT_dec (av);

  return 0;
}

#define PERL_MAGIC_coro PERL_MAGIC_ext

static MGVTBL vtbl_coro = {0, 0, 0, 0, coro_cv_free};

#define CORO_MAGIC(cv)					\
    SvMAGIC (cv)					\
       ? SvMAGIC (cv)->mg_type == PERL_MAGIC_coro	\
          ? SvMAGIC (cv)				\
          : mg_find ((SV *)cv, PERL_MAGIC_coro)		\
       : 0

static struct coro *
SvSTATE_ (pTHX_ SV *coro)
{
  HV *stash;
  MAGIC *mg;

  if (SvROK (coro))
    coro = SvRV (coro);

  if (SvTYPE (coro) != SVt_PVHV)
    croak ("Coro::State object required");

  stash = SvSTASH (coro);
  if (stash != coro_stash && stash != coro_state_stash)
    {
      /* very slow, but rare, check */
      if (!sv_derived_from (sv_2mortal (newRV_inc (coro)), "Coro::State"))
        croak ("Coro::State object required");
    }

  mg = CORO_MAGIC (coro);
  return (struct coro *)mg->mg_ptr;
}

#define SvSTATE(sv) SvSTATE_ (aTHX_ (sv))

/* the next two functions merely cache the padlists */
static void
get_padlist (pTHX_ CV *cv)
{
  MAGIC *mg = CORO_MAGIC (cv);
  AV *av;

  if (mg && AvFILLp ((av = (AV *)mg->mg_obj)) >= 0)
    CvPADLIST (cv) = (AV *)AvARRAY (av)[AvFILLp (av)--];
  else
   {
#if CORO_PREFER_PERL_FUNCTIONS
     /* this is probably cleaner, but also slower? */
     CV *cp = Perl_cv_clone (cv);
     CvPADLIST (cv) = CvPADLIST (cp);
     CvPADLIST (cp) = 0;
     SvREFCNT_dec (cp);
#else
     CvPADLIST (cv) = coro_clone_padlist (aTHX_ cv);
#endif
   }
}

static void
put_padlist (pTHX_ CV *cv)
{
  MAGIC *mg = CORO_MAGIC (cv);
  AV *av;

  if (!mg)
    {
      sv_magic ((SV *)cv, 0, PERL_MAGIC_coro, 0, 0);
      mg = mg_find ((SV *)cv, PERL_MAGIC_coro);
      mg->mg_virtual = &vtbl_coro;
      mg->mg_obj = (SV *)newAV ();
    }

  av = (AV *)mg->mg_obj;

  if (AvFILLp (av) >= AvMAX (av))
    av_extend (av, AvMAX (av) + 1);

  AvARRAY (av)[++AvFILLp (av)] = (SV *)CvPADLIST (cv);
}

/** load & save, init *******************************************************/

static void
load_perl (pTHX_ Coro__State c)
{
#define VAR(name,type) PL_ ## name = c->name;
# include "state.h"
#undef VAR

  GvSV (PL_defgv) = c->defsv;
  GvAV (PL_defgv) = c->defav;
  GvSV (PL_errgv) = c->errsv;
  GvSV (irsgv)    = c->irssv_sv;

  {
    dSP;
    CV *cv;

    /* now do the ugly restore mess */
    while ((cv = (CV *)POPs))
      {
        put_padlist (aTHX_ cv); /* mark this padlist as available */
        CvDEPTH (cv) = PTR2IV (POPs);
        CvPADLIST (cv) = (AV *)POPs;
      }

    PUTBACK;
  }
}

static void
save_perl (pTHX_ Coro__State c)
{
  {
    dSP;
    I32 cxix = cxstack_ix;
    PERL_CONTEXT *ccstk = cxstack;
    PERL_SI *top_si = PL_curstackinfo;

    /*
     * the worst thing you can imagine happens first - we have to save
     * (and reinitialize) all cv's in the whole callchain :(
     */

    XPUSHs (Nullsv);
    /* this loop was inspired by pp_caller */
    for (;;)
      {
        while (cxix >= 0)
          {
            PERL_CONTEXT *cx = &ccstk[cxix--];

            if (CxTYPE (cx) == CXt_SUB || CxTYPE (cx) == CXt_FORMAT)
              {
                CV *cv = cx->blk_sub.cv;

                if (CvDEPTH (cv))
                  {
                    EXTEND (SP, 3);
                    PUSHs ((SV *)CvPADLIST (cv));
                    PUSHs (INT2PTR (SV *, CvDEPTH (cv)));
                    PUSHs ((SV *)cv);

                    CvDEPTH (cv) = 0;
                    get_padlist (aTHX_ cv);
                  }
              }
          }

        if (top_si->si_type == PERLSI_MAIN)
          break;

        top_si = top_si->si_prev;
        ccstk  = top_si->si_cxstack;
        cxix   = top_si->si_cxix;
      }

    PUTBACK;
  }

  c->defav    = GvAV (PL_defgv);
  c->defsv    = DEFSV;
  c->errsv    = ERRSV;
  c->irssv_sv = GvSV (irsgv);

#define VAR(name,type)c->name = PL_ ## name;
# include "state.h"
#undef VAR
}

/*
 * allocate various perl stacks. This is an exact copy
 * of perl.c:init_stacks, except that it uses less memory
 * on the (sometimes correct) assumption that coroutines do
 * not usually need a lot of stackspace.
 */
#if CORO_PREFER_PERL_FUNCTIONS
# define coro_init_stacks init_stacks
#else
static void
coro_init_stacks (pTHX)
{
    PL_curstackinfo = new_stackinfo(64, 6);
    PL_curstackinfo->si_type = PERLSI_MAIN;
    PL_curstack = PL_curstackinfo->si_stack;
    PL_mainstack = PL_curstack;		/* remember in case we switch stacks */

    PL_stack_base = AvARRAY(PL_curstack);
    PL_stack_sp = PL_stack_base;
    PL_stack_max = PL_stack_base + AvMAX(PL_curstack);

    New(50,PL_tmps_stack,64,SV*);
    PL_tmps_floor = -1;
    PL_tmps_ix = -1;
    PL_tmps_max = 64;

    New(54,PL_markstack,16,I32);
    PL_markstack_ptr = PL_markstack;
    PL_markstack_max = PL_markstack + 16;

#ifdef SET_MARK_OFFSET
    SET_MARK_OFFSET;
#endif

    New(54,PL_scopestack,16,I32);
    PL_scopestack_ix = 0;
    PL_scopestack_max = 16;

    New(54,PL_savestack,64,ANY);
    PL_savestack_ix = 0;
    PL_savestack_max = 64;

#if !PERL_VERSION_ATLEAST (5,9,0)
    New(54,PL_retstack,4,OP*);
    PL_retstack_ix = 0;
    PL_retstack_max = 4;
#endif
}
#endif

/*
 * destroy the stacks, the callchain etc...
 */
static void
coro_destroy_stacks (pTHX)
{
  while (PL_curstackinfo->si_next)
    PL_curstackinfo = PL_curstackinfo->si_next;

  while (PL_curstackinfo)
    {
      PERL_SI *p = PL_curstackinfo->si_prev;

      if (!IN_DESTRUCT)
        SvREFCNT_dec (PL_curstackinfo->si_stack);

      Safefree (PL_curstackinfo->si_cxstack);
      Safefree (PL_curstackinfo);
      PL_curstackinfo = p;
  }

  Safefree (PL_tmps_stack);
  Safefree (PL_markstack);
  Safefree (PL_scopestack);
  Safefree (PL_savestack);
#if !PERL_VERSION_ATLEAST (5,9,0)
  Safefree (PL_retstack);
#endif
}

static size_t
coro_rss (pTHX_ struct coro *coro)
{
  size_t rss = sizeof (*coro);

  if (coro->mainstack)
    {
      if (coro->flags & CF_RUNNING)
        {
          #define VAR(name,type)coro->name = PL_ ## name;
          # include "state.h"
          #undef VAR
        }

      rss += sizeof (coro->curstackinfo);
      rss += sizeof (SV) + sizeof (struct xpvav) + (1 + AvFILL (coro->curstackinfo->si_stack)) * sizeof (SV *);
      rss += (coro->curstackinfo->si_cxmax + 1) * sizeof (PERL_CONTEXT);
      rss += sizeof (SV) + sizeof (struct xpvav) + (1 + AvFILL (coro->curstack)) * sizeof (SV *);
      rss += coro->tmps_max * sizeof (SV *);
      rss += (coro->markstack_max - coro->markstack_ptr) * sizeof (I32);
      rss += coro->scopestack_max * sizeof (I32);
      rss += coro->savestack_max * sizeof (ANY);

#if !PERL_VERSION_ATLEAST (5,9,0)
      rss += coro->retstack_max * sizeof (OP *);
#endif
    }

  return rss;
}

/** coroutine stack handling ************************************************/

static void
coro_setup (pTHX_ struct coro *coro)
{
  /*
   * emulate part of the perl startup here.
   */
  coro_init_stacks (aTHX);

  PL_runops     = RUNOPS_DEFAULT;
  PL_curcop     = &PL_compiling;
  PL_in_eval    = EVAL_NULL;
  PL_comppad    = 0;
  PL_curpm      = 0;
  PL_localizing = 0;
  PL_dirty      = 0;
  PL_restartop  = 0;
  
  GvSV (PL_defgv)    = NEWSV (0, 0);
  GvAV (PL_defgv)    = coro->args; coro->args = 0;
  GvSV (PL_errgv)    = NEWSV (0, 0);
  GvSV (irsgv)       = newSVpvn ("\n", 1); sv_magic (GvSV (irsgv), (SV *)irsgv, PERL_MAGIC_sv, "/", 0);
  PL_rs              = newSVsv (GvSV (irsgv));

  {
    IO *io = newIO ();
    PL_defoutgv = newGVgen ("Coro");
    GvIOp(PL_defoutgv) = io;
    IoTYPE (io) = IoTYPE_WRONLY;
    IoOFP (io) = IoIFP (io) = PerlIO_stdout ();
    IoFLAGS (io) |= IOf_FLUSH;
  }

  {
    dSP;
    LOGOP myop;

    Zero (&myop, 1, LOGOP);
    myop.op_next = Nullop;
    myop.op_flags = OPf_WANT_VOID;

    PUSHMARK (SP);
    XPUSHs (av_shift (GvAV (PL_defgv)));
    PUTBACK;
    PL_op = (OP *)&myop;
    PL_op = PL_ppaddr[OP_ENTERSUB](aTHX);
    SPAGAIN;
  }

  ENTER; /* necessary e.g. for dounwind */
}

static void
coro_destroy (pTHX_ struct coro *coro)
{
  if (!IN_DESTRUCT)
    {
      /* restore all saved variables and stuff */
      LEAVE_SCOPE (0);
      assert (PL_tmps_floor == -1);

      /* free all temporaries */
      FREETMPS;
      assert (PL_tmps_ix == -1);

      /* unwind all extra stacks */
      POPSTACK_TO (PL_mainstack);

      /* unwind main stack */
      dounwind (-1);
    }

  SvREFCNT_dec (GvSV (PL_defgv));
  SvREFCNT_dec (GvAV (PL_defgv));
  SvREFCNT_dec (GvSV (PL_errgv));
  SvREFCNT_dec (PL_defoutgv);
  SvREFCNT_dec (PL_rs);
  SvREFCNT_dec (GvSV (irsgv));

  SvREFCNT_dec (coro->saved_deffh);
  //SvREFCNT_dec (coro->throw);

  coro_destroy_stacks (aTHX);
}

static void
free_coro_mortal (pTHX)
{
  if (coro_mortal)
    {
      SvREFCNT_dec (coro_mortal);
      coro_mortal = 0;
    }
}

static int
runops_trace (pTHX)
{
  COP *oldcop = 0;
  int oldcxix = -2;
  struct coro *coro = SvSTATE (coro_current); /* trace cctx is tied to specific coro */
  coro_cctx *cctx = coro->cctx;

  while ((PL_op = CALL_FPTR (PL_op->op_ppaddr) (aTHX)))
    {
      PERL_ASYNC_CHECK ();

      if (cctx->flags & CC_TRACE_ALL)
        {
          if (PL_op->op_type == OP_LEAVESUB && cctx->flags & CC_TRACE_SUB)
            {
              PERL_CONTEXT *cx = &cxstack[cxstack_ix];
              SV **bot, **top;
              AV *av = newAV (); /* return values */
              SV **cb;
              dSP;

              GV *gv = CvGV (cx->blk_sub.cv);
              SV *fullname = sv_2mortal (newSV (0));
              if (isGV (gv))
                gv_efullname3 (fullname, gv, 0);

              bot = PL_stack_base + cx->blk_oldsp + 1;
              top = cx->blk_gimme == G_ARRAY  ? SP + 1
                  : cx->blk_gimme == G_SCALAR ? bot + 1
                  :                             bot;

              while (bot < top)
                av_push (av, SvREFCNT_inc (*bot++));

              PL_runops = RUNOPS_DEFAULT;
              ENTER;
              SAVETMPS;
              EXTEND (SP, 3);
              PUSHMARK (SP);
              PUSHs (&PL_sv_no);
              PUSHs (fullname);
              PUSHs (sv_2mortal (newRV_noinc ((SV *)av)));
              PUTBACK;
              cb = hv_fetch ((HV *)SvRV (coro_current), "_trace_sub_cb", sizeof ("_trace_sub_cb") - 1, 0);
              if (cb) call_sv (*cb, G_KEEPERR | G_EVAL | G_VOID | G_DISCARD);
              SPAGAIN;
              FREETMPS;
              LEAVE;
              PL_runops = runops_trace;
            }

          if (oldcop != PL_curcop)
            {
              oldcop = PL_curcop;

              if (PL_curcop != &PL_compiling)
                {
                  SV **cb;

                  if (oldcxix != cxstack_ix && cctx->flags & CC_TRACE_SUB)
                    {
                      PERL_CONTEXT *cx = &cxstack[cxstack_ix];

                      if (CxTYPE (cx) == CXt_SUB && oldcxix < cxstack_ix)
                        {
                          runops_proc_t old_runops = PL_runops;
                          dSP;
                          GV *gv = CvGV (cx->blk_sub.cv);
                          SV *fullname = sv_2mortal (newSV (0));

                          if (isGV (gv))
                            gv_efullname3 (fullname, gv, 0);

                          PL_runops = RUNOPS_DEFAULT;
                          ENTER;
                          SAVETMPS;
                          EXTEND (SP, 3);
                          PUSHMARK (SP);
                          PUSHs (&PL_sv_yes);
                          PUSHs (fullname);
                          PUSHs (cx->blk_sub.hasargs ? sv_2mortal (newRV_inc ((SV *)cx->blk_sub.argarray)) : &PL_sv_undef);
                          PUTBACK;
                          cb = hv_fetch ((HV *)SvRV (coro_current), "_trace_sub_cb", sizeof ("_trace_sub_cb") - 1, 0);
                          if (cb) call_sv (*cb, G_KEEPERR | G_EVAL | G_VOID | G_DISCARD);
                          SPAGAIN;
                          FREETMPS;
                          LEAVE;
                          PL_runops = runops_trace;
                        }

                      oldcxix = cxstack_ix;
                    }

                  if (cctx->flags & CC_TRACE_LINE)
                    {
                      dSP;

                      PL_runops = RUNOPS_DEFAULT;
                      ENTER;
                      SAVETMPS;
                      EXTEND (SP, 3);
                      PL_runops = RUNOPS_DEFAULT;
                      PUSHMARK (SP);
                      PUSHs (sv_2mortal (newSVpv (OutCopFILE (oldcop), 0)));
                      PUSHs (sv_2mortal (newSViv (CopLINE (oldcop))));
                      PUTBACK;
                      cb = hv_fetch ((HV *)SvRV (coro_current), "_trace_line_cb", sizeof ("_trace_line_cb") - 1, 0);
                      if (cb) call_sv (*cb, G_KEEPERR | G_EVAL | G_VOID | G_DISCARD);
                      SPAGAIN;
                      FREETMPS;
                      LEAVE;
                      PL_runops = runops_trace;
                    }
                }
            }
        }
    }

  TAINT_NOT;
  return 0;
}

/* inject a fake call to Coro::State::_cctx_init into the execution */
/* _cctx_init should be careful, as it could be called at almost any time */
/* during execution of a perl program */
static void NOINLINE
prepare_cctx (pTHX_ coro_cctx *cctx)
{
  dSP;
  LOGOP myop;

  PL_top_env = &PL_start_env;

  if (cctx->flags & CC_TRACE)
    PL_runops = runops_trace;

  Zero (&myop, 1, LOGOP);
  myop.op_next = PL_op;
  myop.op_flags = OPf_WANT_VOID | OPf_STACKED;

  PUSHMARK (SP);
  EXTEND (SP, 2);
  PUSHs (sv_2mortal (newSViv (PTR2IV (cctx))));
  PUSHs ((SV *)get_cv ("Coro::State::_cctx_init", FALSE));
  PUTBACK;
  PL_op = (OP *)&myop;
  PL_op = PL_ppaddr[OP_ENTERSUB](aTHX);
  SPAGAIN;
}

/*
 * this is a _very_ stripped down perl interpreter ;)
 */
static void
coro_run (void *arg)
{
  dTHX;

  /* coro_run is the alternative tail of transfer(), so unlock here. */
  UNLOCK;

  /* we now skip the entersub that lead to transfer() */
  PL_op = PL_op->op_next;

  /* inject a fake subroutine call to cctx_init */
  prepare_cctx (aTHX_ (coro_cctx *)arg);

  /* somebody or something will hit me for both perl_run and PL_restartop */
  PL_restartop = PL_op;
  perl_run (PL_curinterp);

  /*
   * If perl-run returns we assume exit() was being called or the coro
   * fell off the end, which seems to be the only valid (non-bug)
   * reason for perl_run to return. We try to exit by jumping to the
   * bootstrap-time "top" top_env, as we cannot restore the "main"
   * coroutine as Coro has no such concept
   */
  PL_top_env = main_top_env;
  JMPENV_JUMP (2); /* I do not feel well about the hardcoded 2 at all */
}

static coro_cctx *
cctx_new ()
{
  coro_cctx *cctx;
  void *stack_start;
  size_t stack_size;

  ++cctx_count;

  Newz (0, cctx, 1, coro_cctx);

#if HAVE_MMAP

  cctx->ssize = ((coro_stacksize * sizeof (long) + PAGESIZE - 1) / PAGESIZE + CORO_STACKGUARD) * PAGESIZE;
  /* mmap supposedly does allocate-on-write for us */
  cctx->sptr = mmap (0, cctx->ssize, PROT_EXEC|PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, 0, 0);

  if (cctx->sptr != (void *)-1)
    {
# if CORO_STACKGUARD
      mprotect (cctx->sptr, CORO_STACKGUARD * PAGESIZE, PROT_NONE);
# endif
      stack_start = CORO_STACKGUARD * PAGESIZE + (char *)cctx->sptr;
      stack_size  = cctx->ssize - CORO_STACKGUARD * PAGESIZE;
      cctx->flags |= CC_MAPPED;
    }
  else
#endif
    {
      cctx->ssize = coro_stacksize * (long)sizeof (long);
      New (0, cctx->sptr, coro_stacksize, long);

      if (!cctx->sptr)
        {
          perror ("FATAL: unable to allocate stack for coroutine");
          _exit (EXIT_FAILURE);
        }

      stack_start = cctx->sptr;
      stack_size  = cctx->ssize;
    }

  REGISTER_STACK (cctx, (char *)stack_start, (char *)stack_start + stack_size);
  coro_create (&cctx->cctx, coro_run, (void *)cctx, stack_start, stack_size);

  return cctx;
}

static void
cctx_destroy (coro_cctx *cctx)
{
  if (!cctx)
    return;

  --cctx_count;

#if CORO_USE_VALGRIND
  VALGRIND_STACK_DEREGISTER (cctx->valgrind_id);
#endif

#if HAVE_MMAP
  if (cctx->flags & CC_MAPPED)
    munmap (cctx->sptr, cctx->ssize);
  else
#endif
    Safefree (cctx->sptr);

  Safefree (cctx);
}

static coro_cctx *
cctx_get (pTHX)
{
  while (cctx_first)
    {
      coro_cctx *cctx = cctx_first;
      cctx_first = cctx->next;
      --cctx_idle;

      if (cctx->ssize >= coro_stacksize && !(cctx->flags & CC_NOREUSE))
        return cctx;

      cctx_destroy (cctx);
    }

  return cctx_new ();
}

static void
cctx_put (coro_cctx *cctx)
{
  /* free another cctx if overlimit */
  if (cctx_idle >= MAX_IDLE_CCTX)
    {
      coro_cctx *first = cctx_first;
      cctx_first = first->next;
      --cctx_idle;

      cctx_destroy (first);
    }

  ++cctx_idle;
  cctx->next = cctx_first;
  cctx_first = cctx;
}

/** coroutine switching *****************************************************/

static void NOINLINE
transfer_check (pTHX_ struct coro *prev, struct coro *next)
{
  if (prev != next)
    {
      if (!(prev->flags & (CF_RUNNING | CF_NEW)))
        croak ("Coro::State::transfer called with non-running/new prev Coro::State, but can only transfer from running or new states");

      if (next->flags & CF_RUNNING)
        croak ("Coro::State::transfer called with running next Coro::State, but can only transfer to inactive states");

      if (next->flags & CF_DESTROYED)
        croak ("Coro::State::transfer called with destroyed next Coro::State, but can only transfer to inactive states");

      if (PL_lex_state != LEX_NOTPARSING)
        croak ("Coro::State::transfer called while parsing, but this is not supported");
    }
}

/* always use the TRANSFER macro */
static void NOINLINE
transfer (pTHX_ struct coro *prev, struct coro *next)
{
  dSTACKLEVEL;

  /* sometimes transfer is only called to set idle_sp */
  if (!next)
    {
      ((coro_cctx *)prev)->idle_sp = STACKLEVEL;
      assert (((coro_cctx *)prev)->idle_te = PL_top_env); /* just for the side-effect when asserts are enabled */
    }
  else if (prev != next)
    {
      coro_cctx *prev__cctx;

      if (prev->flags & CF_NEW)
        {
          /* create a new empty context */
          Newz (0, prev->cctx, 1, coro_cctx);
          prev->flags &= ~CF_NEW;
          prev->flags |=  CF_RUNNING;
        }

      prev->flags &= ~CF_RUNNING;
      next->flags |=  CF_RUNNING;

      LOCK;

      if (next->flags & CF_NEW)
        {
          /* need to start coroutine */
          next->flags &= ~CF_NEW;
          /* first get rid of the old state */
          save_perl (aTHX_ prev);
          /* setup coroutine call */
          coro_setup (aTHX_ next);
        }
      else
        {
          /* coroutine already started */
          save_perl (aTHX_ prev);
          load_perl (aTHX_ next);
        }

      prev__cctx = prev->cctx;

      /* possibly "free" the cctx */
      if (prev__cctx->idle_sp == STACKLEVEL && !(prev__cctx->flags & CC_TRACE))
        {
          /* I assume that STACKLEVEL is a stronger indicator than PL_top_env changes */
          assert (("ERROR: current top_env must equal previous top_env", PL_top_env == prev__cctx->idle_te));

          prev->cctx = 0;

          cctx_put (prev__cctx);
        }

      ++next->usecount;

      if (!next->cctx)
        next->cctx = cctx_get (aTHX);

      if (prev__cctx != next->cctx)
        {
          prev__cctx->top_env = PL_top_env;
          PL_top_env = next->cctx->top_env;
          coro_transfer (&prev__cctx->cctx, &next->cctx->cctx);
        }

      free_coro_mortal (aTHX);
      UNLOCK;
    }
}

struct transfer_args
{
  struct coro *prev, *next;
};

#define TRANSFER(ta) transfer (aTHX_ (ta).prev, (ta).next)
#define TRANSFER_CHECK(ta) transfer_check (aTHX_ (ta).prev, (ta).next)

/** high level stuff ********************************************************/

static int
coro_state_destroy (pTHX_ struct coro *coro)
{
  if (coro->flags & CF_DESTROYED)
    return 0;

  coro->flags |= CF_DESTROYED;
  
  if (coro->flags & CF_READY)
    {
      /* reduce nready, as destroying a ready coro effectively unreadies it */
      /* alternative: look through all ready queues and remove the coro */
      LOCK;
      --coro_nready;
      UNLOCK;
    }
  else
    coro->flags |= CF_READY; /* make sure it is NOT put into the readyqueue */

  if (coro->mainstack && coro->mainstack != main_mainstack)
    {
      struct coro temp;

      if (coro->flags & CF_RUNNING)
        croak ("FATAL: tried to destroy currently running coroutine");

      save_perl (aTHX_ &temp);
      load_perl (aTHX_ coro);

      coro_destroy (aTHX_ coro);

      load_perl (aTHX_ &temp); /* this will get rid of defsv etc.. */

      coro->mainstack = 0;
    }

  cctx_destroy (coro->cctx);
  SvREFCNT_dec (coro->args);

  if (coro->next) coro->next->prev = coro->prev;
  if (coro->prev) coro->prev->next = coro->next;
  if (coro == coro_first) coro_first = coro->next;

  return 1;
}

static int
coro_state_free (pTHX_ SV *sv, MAGIC *mg)
{
  struct coro *coro = (struct coro *)mg->mg_ptr;
  mg->mg_ptr = 0;

  coro->hv = 0;

  if (--coro->refcnt < 0)
    {
      coro_state_destroy (aTHX_ coro);
      Safefree (coro);
    }

  return 0;
}

static int
coro_state_dup (pTHX_ MAGIC *mg, CLONE_PARAMS *params)
{
  struct coro *coro = (struct coro *)mg->mg_ptr;

  ++coro->refcnt;

  return 0;
}

static MGVTBL coro_state_vtbl = {
  0, 0, 0, 0,
  coro_state_free,
  0,
#ifdef MGf_DUP
  coro_state_dup,
#else
# define MGf_DUP 0
#endif
};

static void
prepare_transfer (pTHX_ struct transfer_args *ta, SV *prev_sv, SV *next_sv)
{
  ta->prev = SvSTATE (prev_sv);
  ta->next = SvSTATE (next_sv);
  TRANSFER_CHECK (*ta);
}

static void
api_transfer (SV *prev_sv, SV *next_sv)
{
  dTHX;
  struct transfer_args ta;

  prepare_transfer (aTHX_ &ta, prev_sv, next_sv);
  TRANSFER (ta);
}

/** Coro ********************************************************************/

static void
coro_enq (pTHX_ SV *coro_sv)
{
  av_push (coro_ready [SvSTATE (coro_sv)->prio - PRIO_MIN], coro_sv);
}

static SV *
coro_deq (pTHX_ int min_prio)
{
  int prio = PRIO_MAX - PRIO_MIN;

  min_prio -= PRIO_MIN;
  if (min_prio < 0)
    min_prio = 0;

  for (prio = PRIO_MAX - PRIO_MIN + 1; --prio >= min_prio; )
    if (AvFILLp (coro_ready [prio]) >= 0)
      return av_shift (coro_ready [prio]);

  return 0;
}

static int
api_ready (SV *coro_sv)
{
  dTHX;
  struct coro *coro;

  if (SvROK (coro_sv))
    coro_sv = SvRV (coro_sv);

  coro = SvSTATE (coro_sv);

  if (coro->flags & CF_READY)
    return 0;

  coro->flags |= CF_READY;

  LOCK;
  coro_enq (aTHX_ SvREFCNT_inc (coro_sv));
  ++coro_nready;
  UNLOCK;

  return 1;
}

static int
api_is_ready (SV *coro_sv)
{
  dTHX;
  return !!(SvSTATE (coro_sv)->flags & CF_READY);
}

static void
prepare_schedule (pTHX_ struct transfer_args *ta)
{
  SV *prev_sv, *next_sv;

  for (;;)
    {
      LOCK;
      next_sv = coro_deq (aTHX_ PRIO_MIN);

      /* nothing to schedule: call the idle handler */
      if (!next_sv)
        {
          dSP;
          UNLOCK;

          ENTER;
          SAVETMPS;

          PUSHMARK (SP);
          PUTBACK;
          call_sv (get_sv ("Coro::idle", FALSE), G_DISCARD);

          FREETMPS;
          LEAVE;
          continue;
        }

      ta->next = SvSTATE (next_sv);

      /* cannot transfer to destroyed coros, skip and look for next */
      if (ta->next->flags & CF_DESTROYED)
        {
          UNLOCK;
          SvREFCNT_dec (next_sv);
          /* coro_nready is already taken care of by destroy */
          continue;
        }

      --coro_nready;
      UNLOCK;
      break;
    }

  /* free this only after the transfer */
  prev_sv = SvRV (coro_current);
  ta->prev = SvSTATE (prev_sv);
  TRANSFER_CHECK (*ta);
  assert (ta->next->flags & CF_READY);
  ta->next->flags &= ~CF_READY;
  SvRV_set (coro_current, next_sv);

  LOCK;
  free_coro_mortal (aTHX);
  coro_mortal = prev_sv;
  UNLOCK;
}

static void
prepare_cede (pTHX_ struct transfer_args *ta)
{
  api_ready (coro_current);
  prepare_schedule (aTHX_ ta);
}

static int
prepare_cede_notself (pTHX_ struct transfer_args *ta)
{
  if (coro_nready)
    {
      SV *prev = SvRV (coro_current);
      prepare_schedule (aTHX_ ta);
      api_ready (prev);
      return 1;
    }
  else
    return 0;
}

static void
api_schedule (void)
{
  dTHX;
  struct transfer_args ta;

  prepare_schedule (aTHX_ &ta);
  TRANSFER (ta);
}

static int
api_cede (void)
{
  dTHX;
  struct transfer_args ta;

  prepare_cede (aTHX_ &ta);

  if (ta.prev != ta.next)
    {
      TRANSFER (ta);
      return 1;
    }
  else
    return 0;
}

static int
api_cede_notself (void)
{
  dTHX;
  struct transfer_args ta;

  if (prepare_cede_notself (aTHX_ &ta))
    {
      TRANSFER (ta);
      return 1;
    }
  else
    return 0;
}

static void
api_trace (SV *coro_sv, int flags)
{
  dTHX;
  struct coro *coro = SvSTATE (coro_sv);

  if (flags & CC_TRACE)
    {
      if (!coro->cctx)
        coro->cctx = cctx_new ();
      else if (!(coro->cctx->flags & CC_TRACE))
        croak ("cannot enable tracing on coroutine with custom stack");

      coro->cctx->flags |= CC_NOREUSE | (flags & (CC_TRACE | CC_TRACE_ALL));
    }
  else if (coro->cctx && coro->cctx->flags & CC_TRACE)
    {
      coro->cctx->flags &= ~(CC_TRACE | CC_TRACE_ALL);

      if (coro->flags & CF_RUNNING)
        PL_runops = RUNOPS_DEFAULT;
      else
        coro->runops = RUNOPS_DEFAULT;
    }
}

MODULE = Coro::State                PACKAGE = Coro::State	PREFIX = api_

PROTOTYPES: DISABLE

BOOT:
{
#ifdef USE_ITHREADS
        MUTEX_INIT (&coro_mutex);
#endif
        BOOT_PAGESIZE;

        irsgv = gv_fetchpv ("/", 1, SVt_PV);

	coro_state_stash = gv_stashpv ("Coro::State", TRUE);

        newCONSTSUB (coro_state_stash, "CC_TRACE"     , newSViv (CC_TRACE));
        newCONSTSUB (coro_state_stash, "CC_TRACE_SUB" , newSViv (CC_TRACE_SUB));
        newCONSTSUB (coro_state_stash, "CC_TRACE_LINE", newSViv (CC_TRACE_LINE));
        newCONSTSUB (coro_state_stash, "CC_TRACE_ALL" , newSViv (CC_TRACE_ALL));

        main_mainstack = PL_mainstack;
        main_top_env   = PL_top_env;

        while (main_top_env->je_prev)
          main_top_env = main_top_env->je_prev;

        coroapi.ver      = CORO_API_VERSION;
        coroapi.transfer = api_transfer;

        assert (("PRIO_NORMAL must be 0", !PRIO_NORMAL));
}

SV *
new (char *klass, ...)
        CODE:
{
        struct coro *coro;
        HV *hv;
        int i;

        Newz (0, coro, 1, struct coro);
        coro->args  = newAV ();
        coro->flags = CF_NEW;

        if (coro_first) coro_first->prev = coro;
        coro->next = coro_first;
        coro_first = coro;

        coro->hv = hv = newHV ();
        sv_magicext ((SV *)hv, 0, PERL_MAGIC_ext, &coro_state_vtbl, (char *)coro, 0)->mg_flags |= MGf_DUP;
        RETVAL = sv_bless (newRV_noinc ((SV *)hv), gv_stashpv (klass, 1));

        for (i = 1; i < items; i++)
          av_push (coro->args, newSVsv (ST (i)));
}
        OUTPUT:
        RETVAL

# these not obviously related functions are all rolled into the same xs
# function to increase chances that they all will call transfer with the same
# stack offset
void
_set_stacklevel (...)
	ALIAS:
        Coro::State::transfer = 1
        Coro::schedule        = 2
        Coro::cede            = 3
        Coro::cede_notself    = 4
        CODE:
{
	struct transfer_args ta;

        switch (ix)
          {
            case 0:
              ta.prev  = (struct coro *)INT2PTR (coro_cctx *, SvIV (ST (0)));
              ta.next  = 0;
              break;

            case 1:
              if (items != 2)
                croak ("Coro::State::transfer (prev,next) expects two arguments, not %d", items);

              prepare_transfer (aTHX_ &ta, ST (0), ST (1));
              break;

            case 2:
              prepare_schedule (aTHX_ &ta);
              break;

            case 3:
              prepare_cede (aTHX_ &ta);
              break;

            case 4:
              if (!prepare_cede_notself (aTHX_ &ta))
                XSRETURN_EMPTY;

              break;
          }

        BARRIER;
        TRANSFER (ta);

        if (GIMME_V != G_VOID && ta.next != ta.prev)
          XSRETURN_YES;
}

bool
_destroy (SV *coro_sv)
	CODE:
	RETVAL = coro_state_destroy (aTHX_ SvSTATE (coro_sv));
	OUTPUT:
        RETVAL

void
_exit (code)
	int	code
        PROTOTYPE: $
	CODE:
	_exit (code);

int
cctx_stacksize (int new_stacksize = 0)
	CODE:
        RETVAL = coro_stacksize;
        if (new_stacksize)
          coro_stacksize = new_stacksize;
	OUTPUT:
        RETVAL

int
cctx_count ()
	CODE:
        RETVAL = cctx_count;
	OUTPUT:
        RETVAL

int
cctx_idle ()
	CODE:
        RETVAL = cctx_idle;
	OUTPUT:
        RETVAL

void
list ()
	PPCODE:
{
  	struct coro *coro;
        for (coro = coro_first; coro; coro = coro->next)
          if (coro->hv)
            XPUSHs (sv_2mortal (newRV_inc ((SV *)coro->hv)));
}

void
call (Coro::State coro, SV *coderef)
	ALIAS:
        eval = 1
	CODE:
{
        if (coro->mainstack)
          {
            struct coro temp;
            Zero (&temp, 1, struct coro);

            if (!(coro->flags & CF_RUNNING))
              {
                save_perl (aTHX_ &temp);
                load_perl (aTHX_ coro);
              }

            {
              dSP;
              ENTER;
              SAVETMPS;
              PUSHMARK (SP);
              PUTBACK;
              if (ix)
                eval_sv (coderef, 0);
              else
                call_sv (coderef, G_KEEPERR | G_EVAL | G_VOID | G_DISCARD);
              SPAGAIN;
              FREETMPS;
              LEAVE;
              PUTBACK;
            }

            if (!(coro->flags & CF_RUNNING))
              {
                save_perl (aTHX_ coro);
                load_perl (aTHX_ &temp);
              }
          }
}

SV *
is_ready (Coro::State coro)
        PROTOTYPE: $
        ALIAS:
        is_ready     = CF_READY
        is_running   = CF_RUNNING
        is_new       = CF_NEW
        is_destroyed = CF_DESTROYED
	CODE:
        RETVAL = boolSV (coro->flags & ix);
	OUTPUT:
        RETVAL

void
api_trace (SV *coro, int flags = CC_TRACE | CC_TRACE_SUB)

SV *
has_stack (Coro::State coro)
        PROTOTYPE: $
	CODE:
        RETVAL = boolSV (!!coro->cctx);
	OUTPUT:
        RETVAL

int
is_traced (Coro::State coro)
        PROTOTYPE: $
	CODE:
        RETVAL = (coro->cctx ? coro->cctx->flags : 0) & CC_TRACE_ALL;
	OUTPUT:
        RETVAL

IV
rss (Coro::State coro)
        PROTOTYPE: $
        ALIAS:
        usecount = 1
        CODE:
        switch (ix)
	  {
            case 0: RETVAL = coro_rss (aTHX_ coro); break;
            case 1: RETVAL = coro->usecount;        break;
          }
	OUTPUT:
        RETVAL


MODULE = Coro::State                PACKAGE = Coro

BOOT:
{
	int i;

        sv_pool_rss   = get_sv ("Coro::POOL_RSS"  , TRUE);
        sv_pool_size  = get_sv ("Coro::POOL_SIZE" , TRUE);
        av_async_pool = get_av ("Coro::async_pool", TRUE);

        coro_current  = get_sv ("Coro::current", FALSE);
        SvREADONLY_on (coro_current);

	coro_stash = gv_stashpv ("Coro",        TRUE);

        newCONSTSUB (coro_stash, "PRIO_MAX",    newSViv (PRIO_MAX));
        newCONSTSUB (coro_stash, "PRIO_HIGH",   newSViv (PRIO_HIGH));
        newCONSTSUB (coro_stash, "PRIO_NORMAL", newSViv (PRIO_NORMAL));
        newCONSTSUB (coro_stash, "PRIO_LOW",    newSViv (PRIO_LOW));
        newCONSTSUB (coro_stash, "PRIO_IDLE",   newSViv (PRIO_IDLE));
        newCONSTSUB (coro_stash, "PRIO_MIN",    newSViv (PRIO_MIN));

        for (i = PRIO_MAX - PRIO_MIN + 1; i--; )
          coro_ready[i] = newAV ();

        {
          SV *sv = perl_get_sv("Coro::API", 1);

          coroapi.schedule     = api_schedule;
          coroapi.cede         = api_cede;
          coroapi.cede_notself = api_cede_notself;
          coroapi.ready        = api_ready;
          coroapi.is_ready     = api_is_ready;
          coroapi.nready       = &coro_nready;
          coroapi.current      = coro_current;

          GCoroAPI = &coroapi;
          sv_setiv (sv, (IV)&coroapi);
          SvREADONLY_on (sv);
        }
}

void
_set_current (SV *current)
        PROTOTYPE: $
	CODE:
        SvREFCNT_dec (SvRV (coro_current));
        SvRV_set (coro_current, SvREFCNT_inc (SvRV (current)));

int
prio (Coro::State coro, int newprio = 0)
        ALIAS:
        nice = 1
        CODE:
{
        RETVAL = coro->prio;

        if (items > 1)
          {
            if (ix)
              newprio = coro->prio - newprio;

            if (newprio < PRIO_MIN) newprio = PRIO_MIN;
            if (newprio > PRIO_MAX) newprio = PRIO_MAX;

            coro->prio = newprio;
          }
}
	OUTPUT:
        RETVAL

SV *
ready (SV *self)
        PROTOTYPE: $
	CODE:
        RETVAL = boolSV (api_ready (self));
	OUTPUT:
        RETVAL

int
nready (...)
	PROTOTYPE:
        CODE:
        RETVAL = coro_nready;
	OUTPUT:
        RETVAL

# for async_pool speedup
void
_pool_1 (SV *cb)
	CODE:
{
	struct coro *coro = SvSTATE (coro_current);
        HV *hv = (HV *)SvRV (coro_current);
        AV *defav = GvAV (PL_defgv);
        SV *invoke = hv_delete (hv, "_invoke", sizeof ("_invoke") - 1, 0);
        AV *invoke_av;
	int i, len;

        if (!invoke)
          croak ("\3terminate\2\n");

        SvREFCNT_dec (coro->saved_deffh);
        coro->saved_deffh = SvREFCNT_inc ((SV *)PL_defoutgv);

        hv_store (hv, "desc", sizeof ("desc") - 1,
                  newSVpvn ("[async_pool]", sizeof ("[async_pool]") - 1), 0);

        invoke_av = (AV *)SvRV (invoke);
        len = av_len (invoke_av);

        sv_setsv (cb, AvARRAY (invoke_av)[0]);

        if (len > 0)
          {
            av_fill (defav, len - 1);
            for (i = 0; i < len; ++i)
              av_store (defav, i, SvREFCNT_inc (AvARRAY (invoke_av)[i + 1]));
          }

        SvREFCNT_dec (invoke);
}

void
_pool_2 (SV *cb)
	CODE:
{
  	struct coro *coro = SvSTATE (coro_current);

        sv_setsv (cb, &PL_sv_undef);

        SvREFCNT_dec ((SV *)PL_defoutgv); PL_defoutgv = (GV *)coro->saved_deffh;
        coro->saved_deffh = 0;

  	if (coro_rss (aTHX_ coro) > SvIV (sv_pool_rss)
            || av_len (av_async_pool) + 1 >= SvIV (sv_pool_size))
          croak ("\3terminate\2\n");

        av_clear (GvAV (PL_defgv));
        hv_store ((HV *)SvRV (coro_current), "desc", sizeof ("desc") - 1,
                  newSVpvn ("[async_pool idle]", sizeof ("[async_pool idle]") - 1), 0);

        coro->prio = 0;

        if (coro->cctx && (coro->cctx->flags & CC_TRACE))
          api_trace (coro_current, 0);

        av_push (av_async_pool, newSVsv (coro_current));
}


MODULE = Coro::State                PACKAGE = Coro::AIO

SV *
_get_state ()
	CODE:
{
	struct io_state *data;

        RETVAL = newSV (sizeof (struct io_state));
	data = (struct io_state *)SvPVX (RETVAL);
        SvCUR_set (RETVAL, sizeof (struct io_state));
        SvPOK_only (RETVAL);

        data->errorno     = errno;
        data->laststype   = PL_laststype;
        data->laststatval = PL_laststatval;
        data->statcache   = PL_statcache;
}
	OUTPUT:
        RETVAL

void
_set_state (char *data_)
	PROTOTYPE: $
	CODE:
{
	struct io_state *data = (void *)data_;

        errno          = data->errorno;
        PL_laststype   = data->laststype;
        PL_laststatval = data->laststatval;
        PL_statcache   = data->statcache;
}

