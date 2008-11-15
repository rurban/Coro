#include "libcoro/coro.c"

#define PERL_NO_GET_CONTEXT
#define PERL_EXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "perliol.h"

#include "patchlevel.h"

#include <stdio.h>
#include <errno.h>
#include <assert.h>

#ifdef WIN32
# undef setjmp
# undef longjmp
# undef _exit
# define setjmp _setjmp // deep magic, don't ask
#else
# include <inttypes.h> /* most portable stdint.h */
#endif

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
#endif

/* the maximum number of idle cctx that will be pooled */
static int cctx_max_idle = 4;

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
#if __GNUC__ >= 4
# define dSTACKLEVEL void *stacklevel = __builtin_frame_address (0)
#else
# define dSTACKLEVEL volatile void *stacklevel = (volatile void *)&stacklevel
#endif

#define IN_DESTRUCT (PL_main_cv == Nullcv)

#if __GNUC__ >= 3
# define attribute(x) __attribute__(x)
# define expect(expr,value) __builtin_expect ((expr),(value))
# define INLINE static inline
#else
# define attribute(x)
# define expect(expr,value) (expr)
# define INLINE static
#endif

#define expect_false(expr) expect ((expr) != 0, 0)
#define expect_true(expr)  expect ((expr) != 0, 1)

#define NOINLINE attribute ((noinline))

#include "CoroAPI.h"

#ifdef USE_ITHREADS

static perl_mutex coro_lock;
# define LOCK   do { MUTEX_LOCK   (&coro_lock); } while (0)
# define UNLOCK do { MUTEX_UNLOCK (&coro_lock); } while (0)
# if CORO_PTHREAD
static void *coro_thx;
# endif

#else

# define LOCK   (void)0
# define UNLOCK (void)0

#endif

# undef LOCK
# define LOCK   (void)0
# undef UNLOCK
# define UNLOCK (void)0

/* helper storage struct for Coro::AIO */
struct io_state
{
  AV *res;
  int errorno;
  I32 laststype; /* U16 in 5.10.0 */
  int laststatval;
  Stat_t statcache;
};

static double (*nvtime)(); /* so why doesn't it take void? */

static U32 cctx_gen;
static size_t cctx_stacksize = CORO_STACKSIZE;
static struct CoroAPI coroapi;
static AV *main_mainstack; /* used to differentiate between $main and others */
static JMPENV *main_top_env;
static HV *coro_state_stash, *coro_stash;
static volatile SV *coro_mortal; /* will be freed/thrown after next transfer */
static volatile struct coro *transfer_next;

static GV *irsgv;    /* $/ */
static GV *stdoutgv; /* *STDOUT */
static SV *rv_diehook;
static SV *rv_warnhook;
static HV *hv_sig;   /* %SIG */

/* async_pool helper stuff */
static SV *sv_pool_rss;
static SV *sv_pool_size;
static AV *av_async_pool;

/* Coro::AnyEvent */
static SV *sv_activity;

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
typedef struct coro_cctx
{
  struct coro_cctx *next;

  /* the stack */
  void *sptr;
  size_t ssize;

  /* cpu state */
  void *idle_sp;   /* sp of top-level transfer/schedule/cede call */
  JMPENV *idle_te; /* same as idle_sp, but for top_env, TODO: remove once stable */
  JMPENV *top_env;
  coro_context cctx;

  U32 gen;
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

/* the structure where most of the perl state is stored, overlaid on the cxstack */
typedef struct
{
  SV *defsv;
  AV *defav;
  SV *errsv;
  SV *irsgv;
#define VAR(name,type) type name;
# include "state.h"
#undef VAR
} perl_slots;

#define SLOT_COUNT ((sizeof (perl_slots) + sizeof (PERL_CONTEXT) - 1) / sizeof (PERL_CONTEXT))

/* this is a structure representing a perl-level coroutine */
struct coro {
  /* the C coroutine allocated to this perl coroutine, if any */
  coro_cctx *cctx;

  /* process data */
  struct CoroSLF slf_frame; /* saved slf frame */
  AV *mainstack;
  perl_slots *slot; /* basically the saved sp */

  AV *args;   /* data associated with this coroutine (initial args) */
  int refcnt; /* coroutines are refcounted, yes */
  int flags;  /* CF_ flags */
  HV *hv;     /* the perl hash associated with this coro, if any */

  /* statistics */
  int usecount; /* number of transfers to this coro */

  /* coro process data */
  int prio;
  SV *throw; /* exception to be thrown */

  /* async_pool */
  SV *saved_deffh;

  /* linked list */
  struct coro *next, *prev;
};

typedef struct coro *Coro__State;
typedef struct coro *Coro__State_or_hashref;

static struct CoroSLF slf_frame; /* the current slf frame */

/** Coro ********************************************************************/

#define PRIO_MAX     3
#define PRIO_HIGH    1
#define PRIO_NORMAL  0
#define PRIO_LOW    -1
#define PRIO_IDLE   -3
#define PRIO_MIN    -4

/* for Coro.pm */
static SV *coro_current;
static SV *coro_readyhook;
static AV *coro_ready [PRIO_MAX - PRIO_MIN + 1];
static struct coro *coro_first;
#define coro_nready coroapi.nready

/** lowlevel stuff **********************************************************/

static SV *
coro_get_sv (pTHX_ const char *name, int create)
{
#if PERL_VERSION_ATLEAST (5,10,0)
         /* silence stupid and wrong 5.10 warning that I am unable to switch off */
         get_sv (name, create);
#endif
  return get_sv (name, create);
}

static AV *
coro_get_av (pTHX_ const char *name, int create)
{
#if PERL_VERSION_ATLEAST (5,10,0)
         /* silence stupid and wrong 5.10 warning that I am unable to switch off */
         get_av (name, create);
#endif
  return get_av (name, create);
}

static HV *
coro_get_hv (pTHX_ const char *name, int create)
{
#if PERL_VERSION_ATLEAST (5,10,0)
         /* silence stupid and wrong 5.10 warning that I am unable to switch off */
         get_hv (name, create);
#endif
  return get_hv (name, create);
}

static AV *
coro_clone_padlist (pTHX_ CV *cv)
{
  AV *padlist = CvPADLIST (cv);
  AV *newpadlist, *newpad;

  newpadlist = newAV ();
  AvREAL_off (newpadlist);
#if PERL_VERSION_ATLEAST (5,10,0)
  Perl_pad_push (aTHX_ padlist, AvFILLp (padlist) + 1);
#else
  Perl_pad_push (aTHX_ padlist, AvFILLp (padlist) + 1, 1);
#endif
  newpad = (AV *)AvARRAY (padlist)[AvFILLp (padlist)];
  --AvFILLp (padlist);

  av_store (newpadlist, 0, SvREFCNT_inc_NN (*av_fetch (padlist, 0, FALSE)));
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

  SvREFCNT_dec (av); /* sv_magicext increased the refcount */

  return 0;
}

#define CORO_MAGIC_type_cv    PERL_MAGIC_ext
#define CORO_MAGIC_type_state PERL_MAGIC_ext

static MGVTBL coro_cv_vtbl = {
  0, 0, 0, 0,
  coro_cv_free
};

#define CORO_MAGIC(sv, type)		\
  SvMAGIC (sv)				\
    ? SvMAGIC (sv)->mg_type == type	\
        ? SvMAGIC (sv)			\
        : mg_find (sv, type)		\
    : 0

#define CORO_MAGIC_cv(cv)    CORO_MAGIC (((SV *)(cv)), CORO_MAGIC_type_cv)
#define CORO_MAGIC_state(sv) CORO_MAGIC (((SV *)(sv)), CORO_MAGIC_type_state)

INLINE struct coro *
SvSTATE_ (pTHX_ SV *coro)
{
  HV *stash;
  MAGIC *mg;

  if (SvROK (coro))
    coro = SvRV (coro);

  if (expect_false (SvTYPE (coro) != SVt_PVHV))
    croak ("Coro::State object required");

  stash = SvSTASH (coro);
  if (expect_false (stash != coro_stash && stash != coro_state_stash))
    {
      /* very slow, but rare, check */
      if (!sv_derived_from (sv_2mortal (newRV_inc (coro)), "Coro::State"))
        croak ("Coro::State object required");
    }

  mg = CORO_MAGIC_state (coro);
  return (struct coro *)mg->mg_ptr;
}

#define SvSTATE(sv) SvSTATE_ (aTHX_ (sv))

/* the next two functions merely cache the padlists */
static void
get_padlist (pTHX_ CV *cv)
{
  MAGIC *mg = CORO_MAGIC_cv (cv);
  AV *av;

  if (expect_true (mg && AvFILLp ((av = (AV *)mg->mg_obj)) >= 0))
    CvPADLIST (cv) = (AV *)AvARRAY (av)[AvFILLp (av)--];
  else
   {
#if CORO_PREFER_PERL_FUNCTIONS
     /* this is probably cleaner? but also slower! */
     /* in practise, it seems to be less stable */
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
  MAGIC *mg = CORO_MAGIC_cv (cv);
  AV *av;

  if (expect_false (!mg))
    mg = sv_magicext ((SV *)cv, (SV *)newAV (), CORO_MAGIC_type_cv, &coro_cv_vtbl, 0, 0);

  av = (AV *)mg->mg_obj;

  if (expect_false (AvFILLp (av) >= AvMAX (av)))
    av_extend (av, AvMAX (av) + 1);

  AvARRAY (av)[++AvFILLp (av)] = (SV *)CvPADLIST (cv);
}

/** load & save, init *******************************************************/

static void
load_perl (pTHX_ Coro__State c)
{
  perl_slots *slot = c->slot;
  c->slot = 0;

  PL_mainstack = c->mainstack;

  GvSV (PL_defgv) = slot->defsv;
  GvAV (PL_defgv) = slot->defav;
  GvSV (PL_errgv) = slot->errsv;
  GvSV (irsgv)    = slot->irsgv;

  #define VAR(name,type) PL_ ## name = slot->name;
  # include "state.h"
  #undef VAR

  {
    dSP;

    CV *cv;

    /* now do the ugly restore mess */
    while (expect_true (cv = (CV *)POPs))
      {
        put_padlist (aTHX_ cv); /* mark this padlist as available */
        CvDEPTH (cv) = PTR2IV (POPs);
        CvPADLIST (cv) = (AV *)POPs;
      }

    PUTBACK;
  }

  slf_frame = c->slf_frame;
}

static void
save_perl (pTHX_ Coro__State c)
{
  c->slf_frame = slf_frame;

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
        while (expect_true (cxix >= 0))
          {
            PERL_CONTEXT *cx = &ccstk[cxix--];

            if (expect_true (CxTYPE (cx) == CXt_SUB || CxTYPE (cx) == CXt_FORMAT))
              {
                CV *cv = cx->blk_sub.cv;

                if (expect_true (CvDEPTH (cv)))
                  {
                    EXTEND (SP, 3);
                    PUSHs ((SV *)CvPADLIST (cv));
                    PUSHs (INT2PTR (SV *, (IV)CvDEPTH (cv)));
                    PUSHs ((SV *)cv);

                    CvDEPTH (cv) = 0;
                    get_padlist (aTHX_ cv);
                  }
              }
          }

        if (expect_true (top_si->si_type == PERLSI_MAIN))
          break;

        top_si = top_si->si_prev;
        ccstk  = top_si->si_cxstack;
        cxix   = top_si->si_cxix;
      }

    PUTBACK;
  }

  /* allocate some space on the context stack for our purposes */
  /* we manually unroll here, as usually 2 slots is enough */
  if (SLOT_COUNT >= 1) CXINC;
  if (SLOT_COUNT >= 2) CXINC;
  if (SLOT_COUNT >= 3) CXINC;
  {
    int i;
    for (i = 3; i < SLOT_COUNT; ++i)
      CXINC;
  }
  cxstack_ix -= SLOT_COUNT; /* undo allocation */

  c->mainstack = PL_mainstack;

  {
    perl_slots *slot = c->slot = (perl_slots *)(cxstack + cxstack_ix + 1);

    slot->defav = GvAV (PL_defgv);
    slot->defsv = DEFSV;
    slot->errsv = ERRSV;
    slot->irsgv = GvSV (irsgv);

    #define VAR(name,type) slot->name = PL_ ## name;
    # include "state.h"
    #undef VAR
  }
}

/*
 * allocate various perl stacks. This is almost an exact copy
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
    PL_curstackinfo = new_stackinfo(32, 8);
    PL_curstackinfo->si_type = PERLSI_MAIN;
    PL_curstack = PL_curstackinfo->si_stack;
    PL_mainstack = PL_curstack;		/* remember in case we switch stacks */

    PL_stack_base = AvARRAY(PL_curstack);
    PL_stack_sp = PL_stack_base;
    PL_stack_max = PL_stack_base + AvMAX(PL_curstack);

    New(50,PL_tmps_stack,32,SV*);
    PL_tmps_floor = -1;
    PL_tmps_ix = -1;
    PL_tmps_max = 32;

    New(54,PL_markstack,16,I32);
    PL_markstack_ptr = PL_markstack;
    PL_markstack_max = PL_markstack + 16;

#ifdef SET_MARK_OFFSET
    SET_MARK_OFFSET;
#endif

    New(54,PL_scopestack,8,I32);
    PL_scopestack_ix = 0;
    PL_scopestack_max = 8;

    New(54,PL_savestack,24,ANY);
    PL_savestack_ix = 0;
    PL_savestack_max = 24;

#if !PERL_VERSION_ATLEAST (5,10,0)
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
coro_destruct_stacks (pTHX)
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
#if !PERL_VERSION_ATLEAST (5,10,0)
  Safefree (PL_retstack);
#endif
}

static size_t
coro_rss (pTHX_ struct coro *coro)
{
  size_t rss = sizeof (*coro);

  if (coro->mainstack)
    {
      perl_slots tmp_slot;
      perl_slots *slot;

      if (coro->flags & CF_RUNNING)
        {
          slot = &tmp_slot;

          #define VAR(name,type) slot->name = PL_ ## name;
          # include "state.h"
          #undef VAR
        }
      else
        slot = coro->slot;

      if (slot)
        {
          rss += sizeof (slot->curstackinfo);
          rss += (slot->curstackinfo->si_cxmax + 1) * sizeof (PERL_CONTEXT);
          rss += sizeof (SV) + sizeof (struct xpvav) + (1 + AvMAX (slot->curstack)) * sizeof (SV *);
          rss += slot->tmps_max * sizeof (SV *);
          rss += (slot->markstack_max - slot->markstack_ptr) * sizeof (I32);
          rss += slot->scopestack_max * sizeof (I32);
          rss += slot->savestack_max * sizeof (ANY);

#if !PERL_VERSION_ATLEAST (5,10,0)
          rss += slot->retstack_max * sizeof (OP *);
#endif
        }
    }

  return rss;
}

/** coroutine stack handling ************************************************/

static int (*orig_sigelem_get) (pTHX_ SV *sv, MAGIC *mg);
static int (*orig_sigelem_set) (pTHX_ SV *sv, MAGIC *mg);
static int (*orig_sigelem_clr) (pTHX_ SV *sv, MAGIC *mg);

/* apparently < 5.8.8 */
#ifndef MgPV_nolen_const
#define MgPV_nolen_const(mg)    (((((int)(mg)->mg_len)) == HEf_SVKEY) ?   \
                                 SvPV_nolen((SV*)((mg)->mg_ptr)) :  \
                                 (const char*)(mg)->mg_ptr)
#endif

/*
 * This overrides the default magic get method of %SIG elements.
 * The original one doesn't provide for reading back of PL_diehook/PL_warnhook
 * and instead of tryign to save and restore the hash elements, we just provide
 * readback here.
 * We only do this when the hook is != 0, as they are often set to 0 temporarily,
 * not expecting this to actually change the hook. This is a potential problem
 * when a schedule happens then, but we ignore this.
 */
static int
coro_sigelem_get (pTHX_ SV *sv, MAGIC *mg)
{
  const char *s = MgPV_nolen_const (mg);

  if (*s == '_')
    {
      SV **svp = 0;

      if (strEQ (s, "__DIE__" )) svp = &PL_diehook;
      if (strEQ (s, "__WARN__")) svp = &PL_warnhook;
      
      if (svp)
        {
          sv_setsv (sv, *svp ? *svp : &PL_sv_undef);
          return 0;
        }
    }

  return orig_sigelem_get ? orig_sigelem_get (aTHX_ sv, mg) : 0;
}

static int
coro_sigelem_clr (pTHX_ SV *sv, MAGIC *mg)
{
  const char *s = MgPV_nolen_const (mg);

  if (*s == '_')
    {
      SV **svp = 0;

      if (strEQ (s, "__DIE__" )) svp = &PL_diehook;
      if (strEQ (s, "__WARN__")) svp = &PL_warnhook;

      if (svp)
        {
          SV *old = *svp;
          *svp = 0;
          SvREFCNT_dec (old);
          return 0;
        }
    }

  return orig_sigelem_clr ? orig_sigelem_clr (aTHX_ sv, mg) : 0;
}

static int
coro_sigelem_set (pTHX_ SV *sv, MAGIC *mg)
{
  const char *s = MgPV_nolen_const (mg);

  if (*s == '_')
    {
      SV **svp = 0;

      if (strEQ (s, "__DIE__" )) svp = &PL_diehook;
      if (strEQ (s, "__WARN__")) svp = &PL_warnhook;

      if (svp)
        {
          SV *old = *svp;
          *svp = newSVsv (sv);
          SvREFCNT_dec (old);
          return 0;
        }
    }

  return orig_sigelem_set ? orig_sigelem_set (aTHX_ sv, mg) : 0;
}

static void
prepare_nop (aTHX_ struct coro_transfer_args *ta)
{
  /* kind of mega-hacky, but works */
  ta->next = ta->prev = (struct coro *)ta;
}

static int
slf_check_nop (aTHX)
{
  return 0;
}

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
  PL_curpad     = 0;
  PL_localizing = 0;
  PL_dirty      = 0;
  PL_restartop  = 0;
#if PERL_VERSION_ATLEAST (5,10,0)
  PL_parser     = 0;
#endif

  /* recreate the die/warn hooks */
  PL_diehook  = 0; SvSetMagicSV (*hv_fetch (hv_sig, "__DIE__" , sizeof ("__DIE__" ) - 1, 1), rv_diehook );
  PL_warnhook = 0; SvSetMagicSV (*hv_fetch (hv_sig, "__WARN__", sizeof ("__WARN__") - 1, 1), rv_warnhook);
  
  GvSV (PL_defgv)    = newSV (0);
  GvAV (PL_defgv)    = coro->args; coro->args = 0;
  GvSV (PL_errgv)    = newSV (0);
  GvSV (irsgv)       = newSVpvn ("\n", 1); sv_magic (GvSV (irsgv), (SV *)irsgv, PERL_MAGIC_sv, "/", 0);
  PL_rs              = newSVsv (GvSV (irsgv));
  PL_defoutgv        = (GV *)SvREFCNT_inc_NN (stdoutgv);

  {
    dSP;
    UNOP myop;

    Zero (&myop, 1, UNOP);
    myop.op_next = Nullop;
    myop.op_flags = OPf_WANT_VOID;

    PUSHMARK (SP);
    XPUSHs (sv_2mortal (av_shift (GvAV (PL_defgv))));
    PUTBACK;
    PL_op = (OP *)&myop;
    PL_op = PL_ppaddr[OP_ENTERSUB](aTHX);
    SPAGAIN;
  }

  /* this newly created coroutine might be run on an existing cctx which most
   * likely was suspended in pp_slf, so we have to emulate entering pp_slf here.
   */
  slf_frame.prepare = prepare_nop;   /* provide a nop function for an eventual pp_slf */
  slf_frame.check   = slf_check_nop; /* signal pp_slf to not repeat */
}

static void
coro_destruct (pTHX_ struct coro *coro)
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

  SvREFCNT_dec (PL_diehook);
  SvREFCNT_dec (PL_warnhook);
  
  SvREFCNT_dec (coro->saved_deffh);
  SvREFCNT_dec (coro->throw);

  coro_destruct_stacks (aTHX);
}

INLINE void
free_coro_mortal (pTHX)
{
  if (expect_true (coro_mortal))
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

              av_extend (av, top - bot);
              while (bot < top)
                av_push (av, SvREFCNT_inc_NN (*bot++));

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
                          PUSHs (CxHASARGS (cx)  ? sv_2mortal (newRV_inc ((SV *)cx->blk_sub.argarray)) : &PL_sv_undef);
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

static void
prepare_set_stacklevel (struct coro_transfer_args *ta, struct coro_cctx *cctx)
{
  ta->prev  = (struct coro *)cctx;
  ta->next  = 0;
}

/* inject a fake call to Coro::State::_cctx_init into the execution */
/* _cctx_init should be careful, as it could be called at almost any time */
/* during execution of a perl program */
/* also initialises PL_top_env */
static void NOINLINE
cctx_prepare (pTHX_ coro_cctx *cctx)
{
  dSP;
  UNOP myop;

  PL_top_env = &PL_start_env;

  if (cctx->flags & CC_TRACE)
    PL_runops = runops_trace;

  Zero (&myop, 1, UNOP);
  myop.op_next  = PL_op;
  myop.op_flags = OPf_WANT_VOID | OPf_STACKED;

  PUSHMARK (SP);
  EXTEND (SP, 2);
  PUSHs (sv_2mortal (newSViv ((IV)cctx)));
  PUSHs ((SV *)get_cv ("Coro::State::_cctx_init", FALSE));
  PUTBACK;
  PL_op = (OP *)&myop;
  PL_op = PL_ppaddr[OP_ENTERSUB](aTHX);
  SPAGAIN;
}

/* the tail of transfer: execute stuff we can only do after a transfer */
INLINE void
transfer_tail (pTHX)
{
  struct coro *next = (struct coro *)transfer_next;
  assert (!(transfer_next = 0)); /* just used for the side effect when asserts are enabled */
  assert (("FATAL: next coroutine was zero in transfer_tail (please report)", next));

  free_coro_mortal (aTHX);
  UNLOCK;

  if (expect_false (next->throw))
    {
      SV *exception = sv_2mortal (next->throw);

      next->throw = 0;
      sv_setsv (ERRSV, exception);
      croak (0);
    }
}

/*
 * this is a _very_ stripped down perl interpreter ;)
 */
static void
cctx_run (void *arg)
{
#ifdef USE_ITHREADS
# if CORO_PTHREAD
  PERL_SET_CONTEXT (coro_thx);
# endif
#endif
  {
    dTHX;

    /* normally we would need to skip the entersub here */
    /* not doing so will re-execute it, which is exactly what we want */
    /* PL_nop = PL_nop->op_next */

    /* inject a fake subroutine call to cctx_init */
    cctx_prepare (aTHX_ (coro_cctx *)arg);

    /* cctx_run is the alternative tail of transfer() */
    /* TODO: throwing an exception here might be deadly, VERIFY */
    transfer_tail (aTHX);

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
}

static coro_cctx *
cctx_new ()
{
  coro_cctx *cctx;

  ++cctx_count;
  New (0, cctx, 1, coro_cctx);

  cctx->gen     = cctx_gen;
  cctx->flags   = 0;
  cctx->idle_sp = 0; /* can be accessed by transfer between cctx_run and set_stacklevel, on throw */

  return cctx;
}

/* create a new cctx only suitable as source */
static coro_cctx *
cctx_new_empty ()
{
  coro_cctx *cctx = cctx_new ();

  cctx->sptr = 0;
  coro_create (&cctx->cctx, 0, 0, 0, 0);

  return cctx;
}

/* create a new cctx suitable as destination/running a perl interpreter */
static coro_cctx *
cctx_new_run ()
{
  coro_cctx *cctx = cctx_new ();
  void *stack_start;
  size_t stack_size;

#if HAVE_MMAP
  cctx->ssize = ((cctx_stacksize * sizeof (long) + PAGESIZE - 1) / PAGESIZE + CORO_STACKGUARD) * PAGESIZE;
  /* mmap supposedly does allocate-on-write for us */
  cctx->sptr = mmap (0, cctx->ssize, PROT_EXEC|PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, 0, 0);

  if (cctx->sptr != (void *)-1)
    {
      #if CORO_STACKGUARD
        mprotect (cctx->sptr, CORO_STACKGUARD * PAGESIZE, PROT_NONE);
      #endif
      stack_start = (char *)cctx->sptr + CORO_STACKGUARD * PAGESIZE;
      stack_size  = cctx->ssize        - CORO_STACKGUARD * PAGESIZE;
      cctx->flags |= CC_MAPPED;
    }
  else
#endif
    {
      cctx->ssize = cctx_stacksize * (long)sizeof (long);
      New (0, cctx->sptr, cctx_stacksize, long);

      if (!cctx->sptr)
        {
          perror ("FATAL: unable to allocate stack for coroutine, exiting.");
          _exit (EXIT_FAILURE);
        }

      stack_start = cctx->sptr;
      stack_size  = cctx->ssize;
    }

  #if CORO_USE_VALGRIND
    cctx->valgrind_id = VALGRIND_STACK_REGISTER ((char *)stack_start, (char *)stack_start + stack_size);
  #endif

  coro_create (&cctx->cctx, cctx_run, (void *)cctx, stack_start, stack_size);

  return cctx;
}

static void
cctx_destroy (coro_cctx *cctx)
{
  if (!cctx)
    return;

  --cctx_count;
  coro_destroy (&cctx->cctx);

  /* coro_transfer creates new, empty cctx's */
  if (cctx->sptr)
    {
      #if CORO_USE_VALGRIND
        VALGRIND_STACK_DEREGISTER (cctx->valgrind_id);
      #endif

#if HAVE_MMAP
      if (cctx->flags & CC_MAPPED)
        munmap (cctx->sptr, cctx->ssize);
      else
#endif
        Safefree (cctx->sptr);
    }

  Safefree (cctx);
}

/* wether this cctx should be destructed */
#define CCTX_EXPIRED(cctx) ((cctx)->gen != cctx_gen || ((cctx)->flags & CC_NOREUSE))

static coro_cctx *
cctx_get (pTHX)
{
  while (expect_true (cctx_first))
    {
      coro_cctx *cctx = cctx_first;
      cctx_first = cctx->next;
      --cctx_idle;

      if (expect_true (!CCTX_EXPIRED (cctx)))
        return cctx;

      cctx_destroy (cctx);
    }

  return cctx_new_run ();
}

static void
cctx_put (coro_cctx *cctx)
{
  assert (("FATAL: cctx_put called on non-initialised cctx in Coro (please report)", cctx->sptr));

  /* free another cctx if overlimit */
  if (expect_false (cctx_idle >= cctx_max_idle))
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

static void
transfer_check (pTHX_ struct coro *prev, struct coro *next)
{
  if (expect_true (prev != next))
    {
      if (expect_false (!(prev->flags & (CF_RUNNING | CF_NEW))))
        croak ("Coro::State::transfer called with non-running/new prev Coro::State, but can only transfer from running or new states,");

      if (expect_false (next->flags & CF_RUNNING))
        croak ("Coro::State::transfer called with running next Coro::State, but can only transfer to inactive states,");

      if (expect_false (next->flags & CF_DESTROYED))
        croak ("Coro::State::transfer called with destroyed next Coro::State, but can only transfer to inactive states,");

#if !PERL_VERSION_ATLEAST (5,10,0)
      if (expect_false (PL_lex_state != LEX_NOTPARSING))
        croak ("Coro::State::transfer called while parsing, but this is not supported in your perl version,");
#endif
    }
}

/* always use the TRANSFER macro */
static void NOINLINE
transfer (pTHX_ struct coro *prev, struct coro *next, int force_cctx)
{
  dSTACKLEVEL;

  /* sometimes transfer is only called to set idle_sp */
  if (expect_false (!next))
    {
      ((coro_cctx *)prev)->idle_sp = stacklevel;
      assert (((coro_cctx *)prev)->idle_te = PL_top_env); /* just for the side-effect when asserts are enabled */
    }
  else if (expect_true (prev != next))
    {
      coro_cctx *prev__cctx;

      if (expect_false (prev->flags & CF_NEW))
        {
          /* create a new empty/source context */
          prev->cctx = cctx_new_empty ();
          prev->flags &= ~CF_NEW;
          prev->flags |=  CF_RUNNING;
        }

      prev->flags &= ~CF_RUNNING;
      next->flags |=  CF_RUNNING;

      LOCK;

      /* first get rid of the old state */
      save_perl (aTHX_ prev);

      if (expect_false (next->flags & CF_NEW))
        {
          /* need to start coroutine */
          next->flags &= ~CF_NEW;
          /* setup coroutine call */
          coro_setup (aTHX_ next);
        }
      else
        load_perl (aTHX_ next);

      prev__cctx = prev->cctx;

      /* possibly untie and reuse the cctx */
      if (expect_true (
            prev__cctx->idle_sp == stacklevel
            && !(prev__cctx->flags & CC_TRACE)
            && !force_cctx
         ))
        {
          /* I assume that stacklevel is a stronger indicator than PL_top_env changes */
          assert (("FATAL: current top_env must equal previous top_env in Coro (please report)", PL_top_env == prev__cctx->idle_te));

          prev->cctx = 0;

          /* if the cctx is about to be destroyed we need to make sure we won't see it in cctx_get */
          /* without this the next cctx_get might destroy the prev__cctx while still in use */
          if (expect_false (CCTX_EXPIRED (prev__cctx)))
            if (!next->cctx)
              next->cctx = cctx_get (aTHX);

          cctx_put (prev__cctx);
        }

      ++next->usecount;

      if (expect_true (!next->cctx))
        next->cctx = cctx_get (aTHX);

      assert (("FATAL: transfer_next already nonzero in Coro (please report)", !transfer_next));
      transfer_next = next;

      if (expect_false (prev__cctx != next->cctx))
        {
          prev__cctx->top_env = PL_top_env;
          PL_top_env = next->cctx->top_env;
          coro_transfer (&prev__cctx->cctx, &next->cctx->cctx);
        }

      transfer_tail (aTHX);
    }
}

#define TRANSFER(ta, force_cctx) transfer (aTHX_ (ta).prev, (ta).next, (force_cctx))
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

      assert (("FATAL: tried to destroy currently running coroutine (please report)", !(coro->flags & CF_RUNNING)));

      save_perl (aTHX_ &temp);
      load_perl (aTHX_ coro);

      coro_destruct (aTHX_ coro);

      load_perl (aTHX_ &temp);

      coro->slot = 0;
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
prepare_transfer (pTHX_ struct coro_transfer_args *ta, SV *prev_sv, SV *next_sv)
{
  ta->prev = SvSTATE (prev_sv);
  ta->next = SvSTATE (next_sv);
  TRANSFER_CHECK (*ta);
}

static void
api_transfer (pTHX_ SV *prev_sv, SV *next_sv)
{
  struct coro_transfer_args ta;

  prepare_transfer (aTHX_ &ta, prev_sv, next_sv);
  TRANSFER (ta, 1);
}

/** Coro ********************************************************************/

static void
coro_enq (pTHX_ SV *coro_sv)
{
  av_push (coro_ready [SvSTATE (coro_sv)->prio - PRIO_MIN], coro_sv);
}

static SV *
coro_deq (pTHX)
{
  int prio;

  for (prio = PRIO_MAX - PRIO_MIN + 1; --prio >= 0; )
    if (AvFILLp (coro_ready [prio]) >= 0)
      return av_shift (coro_ready [prio]);

  return 0;
}

static int
api_ready (pTHX_ SV *coro_sv)
{
  struct coro *coro;
  SV *sv_hook;
  void (*xs_hook)(void);

  if (SvROK (coro_sv))
    coro_sv = SvRV (coro_sv);

  coro = SvSTATE (coro_sv);

  if (coro->flags & CF_READY)
    return 0;

  coro->flags |= CF_READY;

  LOCK;

  sv_hook = coro_nready ? 0 : coro_readyhook;
  xs_hook = coro_nready ? 0 : coroapi.readyhook;

  coro_enq (aTHX_ SvREFCNT_inc_NN (coro_sv));
  ++coro_nready;

  UNLOCK;
  
  if (sv_hook)
    {
      dSP;

      ENTER;
      SAVETMPS;

      PUSHMARK (SP);
      PUTBACK;
      call_sv (sv_hook, G_DISCARD);
      SPAGAIN;

      FREETMPS;
      LEAVE;
    }

  if (xs_hook)
    xs_hook ();

  return 1;
}

static int
api_is_ready (pTHX_ SV *coro_sv)
{
  return !!(SvSTATE (coro_sv)->flags & CF_READY);
}

INLINE void
prepare_schedule (pTHX_ struct coro_transfer_args *ta)
{
  SV *prev_sv, *next_sv;

  for (;;)
    {
      LOCK;
      next_sv = coro_deq (aTHX);

      /* nothing to schedule: call the idle handler */
      if (expect_false (!next_sv))
        {
          dSP;
          UNLOCK;

          ENTER;
          SAVETMPS;

          PUSHMARK (SP);
          PUTBACK;
          call_sv (get_sv ("Coro::idle", FALSE), G_DISCARD);
          SPAGAIN;

          FREETMPS;
          LEAVE;
          continue;
        }

      ta->next = SvSTATE (next_sv);

      /* cannot transfer to destroyed coros, skip and look for next */
      if (expect_false (ta->next->flags & CF_DESTROYED))
        {
          UNLOCK;
          SvREFCNT_dec (next_sv);
          /* coro_nready has already been taken care of by destroy */
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
  assert (("FATAL: next coroutine isn't marked as ready in Coro (please report)", ta->next->flags & CF_READY));
  ta->next->flags &= ~CF_READY;
  SvRV_set (coro_current, next_sv);

  LOCK;
  free_coro_mortal (aTHX);
  coro_mortal = prev_sv;
  UNLOCK;
}

INLINE void
prepare_cede (pTHX_ struct coro_transfer_args *ta)
{
  api_ready (aTHX_ coro_current);
  prepare_schedule (aTHX_ ta);
}

INLINE void
prepare_cede_notself (pTHX_ struct coro_transfer_args *ta)
{
  SV *prev = SvRV (coro_current);

  if (coro_nready)
    {
      prepare_schedule (aTHX_ ta);
      api_ready (aTHX_ prev);
    }
  else
    prepare_nop (aTHX_ ta);
}

static void
api_schedule (pTHX)
{
  struct coro_transfer_args ta;

  prepare_schedule (aTHX_ &ta);
  TRANSFER (ta, 1);
}

static int
api_cede (pTHX)
{
  struct coro_transfer_args ta;

  prepare_cede (aTHX_ &ta);

  if (expect_true (ta.prev != ta.next))
    {
      TRANSFER (ta, 1);
      return 1;
    }
  else
    return 0;
}

static int
api_cede_notself (pTHX)
{
  if (coro_nready)
    {
      struct coro_transfer_args ta;

      prepare_cede_notself (aTHX_ &ta);
      TRANSFER (ta, 1);
      return 1;
    }
  else
    return 0;
}

static void
api_trace (pTHX_ SV *coro_sv, int flags)
{
  struct coro *coro = SvSTATE (coro_sv);

  if (flags & CC_TRACE)
    {
      if (!coro->cctx)
        coro->cctx = cctx_new_run ();
      else if (!(coro->cctx->flags & CC_TRACE))
        croak ("cannot enable tracing on coroutine with custom stack,");

      coro->cctx->flags |= CC_NOREUSE | (flags & (CC_TRACE | CC_TRACE_ALL));
    }
  else if (coro->cctx && coro->cctx->flags & CC_TRACE)
    {
      coro->cctx->flags &= ~(CC_TRACE | CC_TRACE_ALL);

      if (coro->flags & CF_RUNNING)
        PL_runops = RUNOPS_DEFAULT;
      else
        coro->slot->runops = RUNOPS_DEFAULT;
    }
}

#if 0
static int
coro_gensub_free (pTHX_ SV *sv, MAGIC *mg)
{
  AV *padlist;
  AV *av = (AV *)mg->mg_obj;

  abort ();

  return 0;
}

static MGVTBL coro_gensub_vtbl = {
  0, 0, 0, 0,
  coro_gensub_free
};
#endif

/*****************************************************************************/
/* PerlIO::cede */

typedef struct
{
  PerlIOBuf base;
  NV next, every;
} PerlIOCede;

static IV
PerlIOCede_pushed (pTHX_ PerlIO *f, const char *mode, SV *arg, PerlIO_funcs *tab)
{
  PerlIOCede *self = PerlIOSelf (f, PerlIOCede);

  self->every = SvCUR (arg) ? SvNV (arg) : 0.01;
  self->next  = nvtime () + self->every;

  return PerlIOBuf_pushed (aTHX_ f, mode, Nullsv, tab);
}

static SV *
PerlIOCede_getarg (pTHX_ PerlIO *f, CLONE_PARAMS *param, int flags)
{
  PerlIOCede *self = PerlIOSelf (f, PerlIOCede);

  return newSVnv (self->every);
}

static IV
PerlIOCede_flush (pTHX_ PerlIO *f)
{
  PerlIOCede *self = PerlIOSelf (f, PerlIOCede);
  double now = nvtime ();

  if (now >= self->next)
    {
      api_cede (aTHX);
      self->next = now + self->every;
    }

  return PerlIOBuf_flush (aTHX_ f);
}

static PerlIO_funcs PerlIO_cede =
{
  sizeof(PerlIO_funcs),
  "cede",
  sizeof(PerlIOCede),
  PERLIO_K_DESTRUCT | PERLIO_K_RAW,
  PerlIOCede_pushed,
  PerlIOBuf_popped,
  PerlIOBuf_open,
  PerlIOBase_binmode,
  PerlIOCede_getarg,
  PerlIOBase_fileno,
  PerlIOBuf_dup,
  PerlIOBuf_read,
  PerlIOBuf_unread,
  PerlIOBuf_write,
  PerlIOBuf_seek,
  PerlIOBuf_tell,
  PerlIOBuf_close,
  PerlIOCede_flush,
  PerlIOBuf_fill,
  PerlIOBase_eof,
  PerlIOBase_error,
  PerlIOBase_clearerr,
  PerlIOBase_setlinebuf,
  PerlIOBuf_get_base,
  PerlIOBuf_bufsiz,
  PerlIOBuf_get_ptr,
  PerlIOBuf_get_cnt,
  PerlIOBuf_set_ptrcnt,
};

/*****************************************************************************/

static const CV *slf_cv; /* for quick consistency check */

static UNOP slf_restore; /* restore stack as entersub did, for first-re-run */
static SV *slf_arg0;
static SV *slf_arg1;
static SV *slf_arg2;

/* this restores the stack in the case we patched the entersub, to */
/* recreate the stack frame as perl will on following calls */
/* since entersub cleared the stack */
static OP *
pp_restore (pTHX)
{
  dSP;

  PUSHMARK (SP);

  EXTEND (SP, 3);
  if (slf_arg0) PUSHs (sv_2mortal (slf_arg0));
  if (slf_arg1) PUSHs (sv_2mortal (slf_arg1));
  if (slf_arg2) PUSHs (sv_2mortal (slf_arg2));
  PUSHs ((SV *)CvGV (slf_cv));

  RETURNOP (slf_restore.op_first);
}

static void
slf_prepare_set_stacklevel (pTHX_ struct coro_transfer_args *ta)
{
  prepare_set_stacklevel (ta, (struct coro_cctx *)slf_frame.data);
}

static void
slf_init_set_stacklevel (pTHX_ struct CoroSLF *frame, SV **arg, int items)
{
  assert (("FATAL: set_stacklevel needs the coro cctx as sole argument", items == 1));

  frame->prepare = slf_prepare_set_stacklevel;
  frame->check   = slf_check_nop;
  frame->data    = (void *)SvIV (arg [0]);
}

static void
slf_prepare_transfer (pTHX_ struct coro_transfer_args *ta)
{
  SV **arg = (SV **)slf_frame.data;

  prepare_transfer (ta, arg [0], arg [1]);
}

static void
slf_init_transfer (pTHX_ struct CoroSLF *frame, SV **arg, int items)
{
  if (items != 2)
    croak ("Coro::State::transfer (prev, next) expects two arguments, not %d,", items);

  frame->prepare = slf_prepare_transfer;
  frame->check   = slf_check_nop;
  frame->data    = (void *)arg; /* let's hope it will stay valid */
}

static void
slf_init_schedule (pTHX_ struct CoroSLF *frame, SV **arg, int items)
{
  frame->prepare = prepare_schedule;
  frame->check   = slf_check_nop;
}

static void
slf_init_cede (pTHX_ struct CoroSLF *frame, SV **arg, int items)
{
  frame->prepare = prepare_cede;
  frame->check   = slf_check_nop;
}

static void
slf_init_cede_notself (pTHX_ struct CoroSLF *frame, SV **arg, int items)
{
  frame->prepare = prepare_cede_notself;
  frame->check   = slf_check_nop;
}

/* we hijack an hopefully unused CV flag for our purposes */
#define CVf_SLF 0x4000

/*
 * these not obviously related functions are all rolled into one
 * function to increase chances that they all will call transfer with the same
 * stack offset
 * SLF stands for "schedule-like-function".
 */
static OP *
pp_slf (pTHX)
{
  I32 checkmark; /* mark SP to see how many elements check has pushed */

  /* set up the slf frame, unless it has already been set-up */
  /* the latter happens when a new coro has been started */
  /* or when a new cctx was attached to an existing coroutine */
  if (expect_true (!slf_frame.prepare))
    {
      /* first iteration */
      dSP;
      SV **arg = PL_stack_base + TOPMARK + 1;
      int items = SP - arg; /* args without function object */
      SV *gv = *sp;

      /* do a quick consistency check on the "function" object, and if it isn't */
      /* for us, divert to the real entersub */
      if (SvTYPE (gv) != SVt_PVGV || !(CvFLAGS (GvCV (gv)) & CVf_SLF))
        return PL_ppaddr[OP_ENTERSUB](aTHX);

      /* pop args */
      SP = PL_stack_base + POPMARK;

      if (!(PL_op->op_flags & OPf_STACKED))
        {
          /* ampersand-form of call, use @_ instead of stack */
          AV *av = GvAV (PL_defgv);
          arg = AvARRAY (av);
          items = AvFILLp (av) + 1;
        }

      PUTBACK;

      ((coro_slf_cb)CvXSUBANY (GvCV (gv)).any_ptr) (aTHX_ &slf_frame, arg, items);
    }

  /* now interpret the slf_frame */
  /* we use a callback system not to make the code needlessly */
  /* complicated, but so we can run multiple perl coros from one cctx */

  do
    {
      struct coro_transfer_args ta;

      slf_frame.prepare (aTHX_ &ta);
      TRANSFER (ta, 0);

      checkmark = PL_stack_sp - PL_stack_base;
    }
  while (slf_frame.check (aTHX_ &slf_frame));

  {
    dSP;
    SV **bot = PL_stack_base + checkmark;
    int gimme = GIMME_V;

    slf_frame.prepare = 0; /* signal pp_slf that we need a new frame */

    /* make sure we put something on the stack in scalar context */
    if (gimme == G_SCALAR)
      {
        if (sp == bot)
          XPUSHs (&PL_sv_undef);

        SP = bot + 1;
      }

    PUTBACK;
  }

  return NORMAL;
}

static void
api_execute_slf (pTHX_ CV *cv, coro_slf_cb init_cb, SV **arg, int items)
{
  assert (("FATAL: SLF call with illegal CV value", !CvANON (cv)));

  if (PL_op->op_ppaddr != PL_ppaddr [OP_ENTERSUB]
      && PL_op->op_ppaddr != pp_slf)
    croak ("FATAL: Coro SLF calls can only be made normally, not via goto or any other means, caught");

  if (items > 3)
    croak ("Coro only supports up to three arguments to SLF functions currently (not %d), caught", items);

  CvFLAGS (cv) |= CVf_SLF;
  CvXSUBANY (cv).any_ptr = (void *)init_cb;
  slf_cv = cv;

  /* we patch the op, and then re-run the whole call */
  /* we have to put the same argument on the stack for this to work */
  /* and this will be done by pp_restore */
  slf_restore.op_next = (OP *)&slf_restore;
  slf_restore.op_type = OP_NULL;
  slf_restore.op_ppaddr = pp_restore;
  slf_restore.op_first = PL_op;

  slf_arg0 = items > 0 ? SvREFCNT_inc (arg [0]) : 0;
  slf_arg1 = items > 1 ? SvREFCNT_inc (arg [1]) : 0;
  slf_arg2 = items > 2 ? SvREFCNT_inc (arg [2]) : 0;

  PL_op->op_ppaddr  = pp_slf;

  PL_op = (OP *)&slf_restore;
}

/*****************************************************************************/

static int
slf_check_semaphore_down (pTHX_ struct CoroSLF *frame)
{
  AV *av = (AV *)frame->data;
  SV *count_sv = AvARRAY (av)[0];

  if (SvIVX (count_sv) > 0)
    {
      SvIVX (count_sv) = SvIVX (count_sv) - 1;
      return 0;
    }
  else
    {
      int i;
      /* if we were woken up but can't down, we look through the whole */
      /* waiters list and only add us if we aren't in there already */
      /* this avoids some degenerate memory usage cases */

      for (i = 1; i <= AvFILLp (av); ++i)
        if (AvARRAY (av)[i] == SvRV (coro_current))
          return 1;

      av_push (av, SvREFCNT_inc (SvRV (coro_current)));
      return 1;
    }
}

static void
slf_init_semaphore_down (pTHX_ struct CoroSLF *frame, SV **arg, int items)
{
  AV *av = (AV *)SvRV (arg [0]);

  if (SvIVX (AvARRAY (av)[0]) > 0)
    {
      frame->data    = (void *)av;
      frame->prepare = prepare_nop;
    }
  else
    {
      av_push (av, SvREFCNT_inc (SvRV (coro_current)));

      frame->data    = (void *)sv_2mortal (SvREFCNT_inc ((SV *)av));
      frame->prepare = prepare_schedule;
    }

  frame->check = slf_check_semaphore_down;

}

MODULE = Coro::State                PACKAGE = Coro::State	PREFIX = api_

PROTOTYPES: DISABLE

BOOT:
{
#ifdef USE_ITHREADS
        MUTEX_INIT (&coro_lock);
# if CORO_PTHREAD
        coro_thx = PERL_GET_CONTEXT;
# endif
#endif
        BOOT_PAGESIZE;

        irsgv    = gv_fetchpv ("/"     , GV_ADD|GV_NOTQUAL, SVt_PV);
        stdoutgv = gv_fetchpv ("STDOUT", GV_ADD|GV_NOTQUAL, SVt_PVIO);

        orig_sigelem_get = PL_vtbl_sigelem.svt_get;   PL_vtbl_sigelem.svt_get   = coro_sigelem_get;
        orig_sigelem_set = PL_vtbl_sigelem.svt_set;   PL_vtbl_sigelem.svt_set   = coro_sigelem_set;
        orig_sigelem_clr = PL_vtbl_sigelem.svt_clear; PL_vtbl_sigelem.svt_clear = coro_sigelem_clr;

        hv_sig      = coro_get_hv (aTHX_ "SIG", TRUE);
        rv_diehook  = newRV_inc ((SV *)gv_fetchpv ("Coro::State::diehook" , 0, SVt_PVCV));
        rv_warnhook = newRV_inc ((SV *)gv_fetchpv ("Coro::State::warnhook", 0, SVt_PVCV));

	coro_state_stash = gv_stashpv ("Coro::State", TRUE);

        newCONSTSUB (coro_state_stash, "CC_TRACE"     , newSViv (CC_TRACE));
        newCONSTSUB (coro_state_stash, "CC_TRACE_SUB" , newSViv (CC_TRACE_SUB));
        newCONSTSUB (coro_state_stash, "CC_TRACE_LINE", newSViv (CC_TRACE_LINE));
        newCONSTSUB (coro_state_stash, "CC_TRACE_ALL" , newSViv (CC_TRACE_ALL));

        main_mainstack = PL_mainstack;
        main_top_env   = PL_top_env;

        while (main_top_env->je_prev)
          main_top_env = main_top_env->je_prev;

        coroapi.ver         = CORO_API_VERSION;
        coroapi.rev         = CORO_API_REVISION;

        coroapi.transfer    = api_transfer;

        coroapi.sv_state             = SvSTATE_;
        coroapi.execute_slf          = api_execute_slf;
        coroapi.prepare_nop          = prepare_nop;
        coroapi.prepare_schedule     = prepare_schedule;
        coroapi.prepare_cede         = prepare_cede;
        coroapi.prepare_cede_notself = prepare_cede_notself;

        {
          SV **svp = hv_fetch (PL_modglobal, "Time::NVtime", 12, 0);

          if (!svp)          croak ("Time::HiRes is required");
          if (!SvIOK (*svp)) croak ("Time::NVtime isn't a function pointer");

          nvtime = INT2PTR (double (*)(), SvIV (*svp));
        }

        assert (("PRIO_NORMAL must be 0", !PRIO_NORMAL));
}

SV *
new (char *klass, ...)
        CODE:
{
        struct coro *coro;
        MAGIC *mg;
        HV *hv;
        int i;

        Newz (0, coro, 1, struct coro);
        coro->args  = newAV ();
        coro->flags = CF_NEW;

        if (coro_first) coro_first->prev = coro;
        coro->next = coro_first;
        coro_first = coro;

        coro->hv = hv = newHV ();
        mg = sv_magicext ((SV *)hv, 0, CORO_MAGIC_type_state, &coro_state_vtbl, (char *)coro, 0);
        mg->mg_flags |= MGf_DUP;
        RETVAL = sv_bless (newRV_noinc ((SV *)hv), gv_stashpv (klass, 1));

        av_extend (coro->args, items - 1);
        for (i = 1; i < items; i++)
          av_push (coro->args, newSVsv (ST (i)));
}
        OUTPUT:
        RETVAL

void
_set_stacklevel (...)
	CODE:
        api_execute_slf (aTHX_ cv, slf_init_set_stacklevel, &ST (0), items);

void
transfer (...)
        PROTOTYPE: $$
	CODE:
        api_execute_slf (aTHX_ cv, slf_init_transfer, &ST (0), items);

bool
_destroy (SV *coro_sv)
	CODE:
	RETVAL = coro_state_destroy (aTHX_ SvSTATE (coro_sv));
	OUTPUT:
        RETVAL

void
_exit (int code)
        PROTOTYPE: $
	CODE:
	_exit (code);

int
cctx_stacksize (int new_stacksize = 0)
	PROTOTYPE: ;$
	CODE:
        RETVAL = cctx_stacksize;
        if (new_stacksize)
          {
            cctx_stacksize = new_stacksize;
            ++cctx_gen;
          }
	OUTPUT:
        RETVAL

int
cctx_max_idle (int max_idle = 0)
	PROTOTYPE: ;$
	CODE:
        RETVAL = cctx_max_idle;
        if (max_idle > 1)
          cctx_max_idle = max_idle;
	OUTPUT:
        RETVAL

int
cctx_count ()
	PROTOTYPE:
	CODE:
        RETVAL = cctx_count;
	OUTPUT:
        RETVAL

int
cctx_idle ()
	PROTOTYPE:
	CODE:
        RETVAL = cctx_idle;
	OUTPUT:
        RETVAL

void
list ()
	PROTOTYPE:
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
        if (coro->mainstack && ((coro->flags & CF_RUNNING) || coro->slot))
          {
            struct coro temp;

            if (!(coro->flags & CF_RUNNING))
              {
                PUTBACK;
                save_perl (aTHX_ &temp);
                load_perl (aTHX_ coro);
              }

            {
              dSP;
              ENTER;
              SAVETMPS;
              PUTBACK;
              PUSHSTACK;
              PUSHMARK (SP);

              if (ix)
                eval_sv (coderef, 0);
              else
                call_sv (coderef, G_KEEPERR | G_EVAL | G_VOID | G_DISCARD);

              POPSTACK;
              SPAGAIN;
              FREETMPS;
              LEAVE;
              PUTBACK;
            }

            if (!(coro->flags & CF_RUNNING))
              {
                save_perl (aTHX_ coro);
                load_perl (aTHX_ &temp);
                SPAGAIN;
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
throw (Coro::State self, SV *throw = &PL_sv_undef)
	PROTOTYPE: $;$
        CODE:
        SvREFCNT_dec (self->throw);
        self->throw = SvOK (throw) ? newSVsv (throw) : 0;

void
api_trace (SV *coro, int flags = CC_TRACE | CC_TRACE_SUB)
	PROTOTYPE: $;$
	C_ARGS: aTHX_ coro, flags

SV *
has_cctx (Coro::State coro)
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

UV
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

void
force_cctx ()
	PROTOTYPE:
	CODE:
        struct coro *coro = SvSTATE (coro_current);
        coro->cctx->idle_sp = 0;

void
swap_defsv (Coro::State self)
	PROTOTYPE: $
        ALIAS:
        swap_defav = 1
        CODE:
	if (!self->slot)
          croak ("cannot swap state with coroutine that has no saved state,");
        else
          {
            SV **src = ix ? (SV **)&GvAV (PL_defgv) : &GvSV (PL_defgv);
            SV **dst = ix ? (SV **)&self->slot->defav : (SV **)&self->slot->defsv;

            SV *tmp = *src; *src = *dst; *dst = tmp;
          }

MODULE = Coro::State                PACKAGE = Coro

BOOT:
{
	int i;

        av_async_pool = coro_get_av (aTHX_ "Coro::async_pool", TRUE);
        sv_pool_rss   = coro_get_sv (aTHX_ "Coro::POOL_RSS"  , TRUE);
        sv_pool_size  = coro_get_sv (aTHX_ "Coro::POOL_SIZE" , TRUE);

        coro_current  = coro_get_sv (aTHX_ "Coro::current", FALSE);
        SvREADONLY_on (coro_current);

	coro_stash = gv_stashpv ("Coro", TRUE);

        newCONSTSUB (coro_stash, "PRIO_MAX",    newSViv (PRIO_MAX));
        newCONSTSUB (coro_stash, "PRIO_HIGH",   newSViv (PRIO_HIGH));
        newCONSTSUB (coro_stash, "PRIO_NORMAL", newSViv (PRIO_NORMAL));
        newCONSTSUB (coro_stash, "PRIO_LOW",    newSViv (PRIO_LOW));
        newCONSTSUB (coro_stash, "PRIO_IDLE",   newSViv (PRIO_IDLE));
        newCONSTSUB (coro_stash, "PRIO_MIN",    newSViv (PRIO_MIN));

        for (i = PRIO_MAX - PRIO_MIN + 1; i--; )
          coro_ready[i] = newAV ();

        {
          SV *sv = coro_get_sv (aTHX_ "Coro::API", TRUE);

          coroapi.schedule     = api_schedule;
          coroapi.cede         = api_cede;
          coroapi.cede_notself = api_cede_notself;
          coroapi.ready        = api_ready;
          coroapi.is_ready     = api_is_ready;
          coroapi.nready       = coro_nready;
          coroapi.current      = coro_current;

          GCoroAPI = &coroapi;
          sv_setiv (sv, (IV)&coroapi);
          SvREADONLY_on (sv);
        }
}

void
schedule (...)
	CODE:
        api_execute_slf (aTHX_ cv, slf_init_schedule, &ST (0), 0);

void
cede (...)
	CODE:
        api_execute_slf (aTHX_ cv, slf_init_cede, &ST (0), 0);

void
cede_notself (...)
	CODE:
        api_execute_slf (aTHX_ cv, slf_init_cede_notself, &ST (0), 0);

void
_set_current (SV *current)
        PROTOTYPE: $
	CODE:
        SvREFCNT_dec (SvRV (coro_current));
        SvRV_set (coro_current, SvREFCNT_inc_NN (SvRV (current)));

void
_set_readyhook (SV *hook)
	PROTOTYPE: $
        CODE:
        LOCK;
        SvREFCNT_dec (coro_readyhook);
        coro_readyhook = SvOK (hook) ? newSVsv (hook) : 0;
        UNLOCK;

int
prio (Coro::State coro, int newprio = 0)
	PROTOTYPE: $;$
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
        RETVAL = boolSV (api_ready (aTHX_ self));
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
          {
            SV *old = PL_diehook;
            PL_diehook = 0;
            SvREFCNT_dec (old);
            croak ("\3async_pool terminate\2\n");
          }

        SvREFCNT_dec (coro->saved_deffh);
        coro->saved_deffh = SvREFCNT_inc_NN ((SV *)PL_defoutgv);

        hv_store (hv, "desc", sizeof ("desc") - 1,
                  newSVpvn ("[async_pool]", sizeof ("[async_pool]") - 1), 0);

        invoke_av = (AV *)SvRV (invoke);
        len = av_len (invoke_av);

        sv_setsv (cb, AvARRAY (invoke_av)[0]);

        if (len > 0)
          {
            av_fill (defav, len - 1);
            for (i = 0; i < len; ++i)
              av_store (defav, i, SvREFCNT_inc_NN (AvARRAY (invoke_av)[i + 1]));
          }
}

void
_pool_2 (SV *cb)
	CODE:
{
  	struct coro *coro = SvSTATE (coro_current);

        sv_setsv (cb, &PL_sv_undef);

        SvREFCNT_dec ((SV *)PL_defoutgv); PL_defoutgv = (GV *)coro->saved_deffh;
        coro->saved_deffh = 0;

  	if (coro_rss (aTHX_ coro) > SvUV (sv_pool_rss)
            || av_len (av_async_pool) + 1 >= SvIV (sv_pool_size))
          {
            SV *old = PL_diehook;
            PL_diehook = 0;
            SvREFCNT_dec (old);
            croak ("\3async_pool terminate\2\n");
          }

        av_clear (GvAV (PL_defgv));
        hv_store ((HV *)SvRV (coro_current), "desc", sizeof ("desc") - 1,
                  newSVpvn ("[async_pool idle]", sizeof ("[async_pool idle]") - 1), 0);

        coro->prio = 0;

        if (coro->cctx && (coro->cctx->flags & CC_TRACE))
          api_trace (aTHX_ coro_current, 0);

        av_push (av_async_pool, newSVsv (coro_current));
}

#if 0

void
_generator_call (...)
	PROTOTYPE: @
        PPCODE:
        fprintf (stderr, "call %p\n", CvXSUBANY(cv).any_ptr);
        xxxx
        abort ();

SV *
gensub (SV *sub, ...)
	PROTOTYPE: &;@
        CODE:
{
        struct coro *coro;
        MAGIC *mg;
        CV *xcv;
        CV *ncv = (CV *)newSV_type (SVt_PVCV);
        int i;

        CvGV   (ncv) = CvGV   (cv);
        CvFILE (ncv) = CvFILE (cv);

        Newz (0, coro, 1, struct coro);
        coro->args  = newAV ();
        coro->flags = CF_NEW;

        av_extend (coro->args, items - 1);
        for (i = 1; i < items; i++)
          av_push (coro->args, newSVsv (ST (i)));

        CvISXSUB_on (ncv);
        CvXSUBANY (ncv).any_ptr = (void *)coro;

        xcv = GvCV (gv_fetchpv ("Coro::_generator_call", 0, SVt_PVCV));

        CvXSUB (ncv) = CvXSUB (xcv);
        CvANON_on (ncv);

        mg = sv_magicext ((SV *)ncv, 0, CORO_MAGIC_type_state, &coro_gensub_vtbl, (char *)coro, 0);
        RETVAL = newRV_noinc ((SV *)ncv);
}
	OUTPUT:
        RETVAL

#endif


MODULE = Coro::State                PACKAGE = Coro::AIO

void
_get_state (SV *self)
	PROTOTYPE: $
	PPCODE:
{
        AV *defav = GvAV (PL_defgv);
        AV *av = newAV ();
        int i;
        SV *data_sv = newSV (sizeof (struct io_state));
	struct io_state *data = (struct io_state *)SvPVX (data_sv);
        SvCUR_set (data_sv, sizeof (struct io_state));
        SvPOK_only (data_sv);

        data->errorno     = errno;
        data->laststype   = PL_laststype;
        data->laststatval = PL_laststatval;
        data->statcache   = PL_statcache;

        av_extend (av, AvFILLp (defav) + 1 + 1);

        for (i = 0; i <= AvFILLp (defav); ++i)
          av_push (av, SvREFCNT_inc_NN (AvARRAY (defav)[i]));

        av_push (av, data_sv);

        XPUSHs (sv_2mortal (newRV_noinc ((SV *)av)));

        api_ready (aTHX_ self);
}

void
_set_state (SV *state)
	PROTOTYPE: $
	PPCODE:
{
  	AV *av = (AV *)SvRV (state);
	struct io_state *data = (struct io_state *)SvPVX (AvARRAY (av)[AvFILLp (av)]);
        int i;

        errno          = data->errorno;
        PL_laststype   = data->laststype;
        PL_laststatval = data->laststatval;
        PL_statcache   = data->statcache;

        EXTEND (SP, AvFILLp (av));
        for (i = 0; i < AvFILLp (av); ++i)
          PUSHs (sv_2mortal (SvREFCNT_inc_NN (AvARRAY (av)[i])));
}


MODULE = Coro::State                PACKAGE = Coro::AnyEvent

BOOT:
        sv_activity = coro_get_sv (aTHX_ "Coro::AnyEvent::ACTIVITY", TRUE);

SV *
_schedule (...)
	CODE:
{
  	static int incede;

        api_cede_notself (aTHX);

        ++incede;
        while (coro_nready >= incede && api_cede (aTHX))
          ;

        sv_setsv (sv_activity, &PL_sv_undef);
        if (coro_nready >= incede)
          {
            PUSHMARK (SP);
            PUTBACK;
            call_pv ("Coro::AnyEvent::_activity", G_DISCARD | G_EVAL);
            SPAGAIN;
          }

        --incede;
}


MODULE = Coro::State                PACKAGE = PerlIO::cede

BOOT:
	PerlIO_define_layer (aTHX_ &PerlIO_cede);

MODULE = Coro::State                PACKAGE = Coro::Semaphore

SV *
new (SV *klass, SV *count_ = 0)
	CODE:
{
        /* a semaphore contains a counter IV in $sem->[0] and any waiters after that */
        AV *av = newAV ();
        av_push (av, newSViv (count_ && SvOK (count_) ? SvIV (count_) : 1));
        RETVAL = sv_bless (newRV_noinc ((SV *)av), GvSTASH (CvGV (cv)));
}
	OUTPUT:
        RETVAL

SV *
count (SV *self)
	CODE:
        RETVAL = newSVsv (AvARRAY ((AV *)SvRV (self))[0]);
	OUTPUT:
        RETVAL

void
up (SV *self, int adjust = 1)
	ALIAS:
        adjust = 1
        CODE:
{
        AV *av = (AV *)SvRV (self);
        SV *count_sv = AvARRAY (av)[0];
        IV count = SvIVX (count_sv);

        count += ix ? adjust : 1;
        SvIVX (count_sv) = count;

        /* now wake up as many waiters as possible */
        while (count > 0 && AvFILLp (av) >= count)
          {
            SV *cb;

            /* swap first two elements so we can shift a waiter */
            AvARRAY (av)[0] = AvARRAY (av)[1];
            AvARRAY (av)[1] = count_sv;
            cb = av_shift (av);

            if (SvOBJECT (cb))
              api_ready (cb);
            else
              croak ("callbacks not yet supported");

            SvREFCNT_dec (cb);
          }
}

void
down (SV *self)
        CODE:
        api_execute_slf (aTHX_ cv, slf_init_semaphore_down, &ST (0), 1);

void
try (SV *self)
        PPCODE:
{
        AV *av = (AV *)SvRV (self);
        SV *count_sv = AvARRAY (av)[0];
        IV count = SvIVX (count_sv);

        if (count > 0)
          {
            --count;
            SvIVX (count_sv) = count;
            XSRETURN_YES;
          }
        else
          XSRETURN_NO;
}

void
waiters (SV *self)
    	CODE:
{
        AV *av = (AV *)SvRV (self);

        if (GIMME_V == G_SCALAR)
          XPUSHs (sv_2mortal (newSVsv (AvARRAY (av)[0])));
        else
          {
            int i;
            EXTEND (SP, AvFILLp (av) + 1 - 1);
            for (i = 1; i <= AvFILLp (av); ++i)
              PUSHs (newSVsv (AvARRAY (av)[i]));
          }
}

