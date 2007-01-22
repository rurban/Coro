#include "libcoro/coro.c"

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

#if USE_VALGRIND
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
# undef STACKGUARD
#endif

#ifndef STACKGUARD
# define STACKGUARD 0
#endif

/* prefer perl internal functions over our own? */
#ifndef PREFER_PERL_FUNCTIONS
# define PREFER_PERL_FUNCTIONS 0
#endif

/* The next macro should declare a variable stacklevel that contains and approximation
 * to the current C stack pointer. Its property is that it changes with each call
 * and should be unique. */
#define dSTACKLEVEL int stacklevel
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

static struct CoroAPI coroapi;
static AV *main_mainstack; /* used to differentiate between $main and others */
static HV *coro_state_stash, *coro_stash;
static SV *coro_mortal; /* will be freed after next transfer */

static struct coro_cctx *cctx_first;
static int cctx_count, cctx_idle;

/* this is a structure representing a c-level coroutine */
typedef struct coro_cctx {
  struct coro_cctx *next;

  /* the stack */
  void *sptr;
  ssize_t ssize; /* positive == mmap, otherwise malloc */

  /* cpu state */
  void *idle_sp;   /* sp of top-level transfer/schedule/cede call */
  JMPENV *idle_te; /* same as idle_sp, but for top_env, TODO: remove once stable */
  JMPENV *top_env;
  coro_context cctx;

  int inuse;

#if USE_VALGRIND
  int valgrind_id;
#endif
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
  int save;  /* CORO_SAVE flags */
  int flags; /* CF_ flags */

  /* optionally saved, might be zero */
  AV *defav; /* @_ */
  SV *defsv; /* $_ */
  SV *errsv; /* $@ */
  SV *irssv; /* $/ */
  SV *irssv_sv; /* real $/ cache */
  
#define VAR(name,type) type name;
# include "state.h"
#undef VAR

  /* coro process data */
  int prio;
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

/** lowlevel stuff **********************************************************/

static AV *
coro_clone_padlist (CV *cv)
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
free_padlist (AV *padlist)
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
    free_padlist (padlist);

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

/* the next two functions merely cache the padlists */
static void
get_padlist (CV *cv)
{
  MAGIC *mg = CORO_MAGIC (cv);
  AV *av;

  if (mg && AvFILLp ((av = (AV *)mg->mg_obj)) >= 0)
    CvPADLIST (cv) = (AV *)AvARRAY (av)[AvFILLp (av)--];
  else
   {
#if PREFER_PERL_FUNCTIONS
     /* this is probably cleaner, but also slower? */
     CV *cp = Perl_cv_clone (cv);
     CvPADLIST (cv) = CvPADLIST (cp);
     CvPADLIST (cp) = 0;
     SvREFCNT_dec (cp);
#else
     CvPADLIST (cv) = coro_clone_padlist (cv);
#endif
   }
}

static void
put_padlist (CV *cv)
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

#define SB do {
#define SE } while (0)

#define REPLACE_SV(sv,val) SB SvREFCNT_dec (sv); (sv) = (val); (val) = 0; SE

static void
load_perl (Coro__State c)
{
#define VAR(name,type) PL_ ## name = c->name;
# include "state.h"
#undef VAR

  if (c->defav) REPLACE_SV (GvAV (PL_defgv), c->defav);
  if (c->defsv) REPLACE_SV (DEFSV          , c->defsv);
  if (c->errsv) REPLACE_SV (ERRSV          , c->errsv);
  if (c->irssv)
    {
      if (c->irssv == PL_rs || sv_eq (PL_rs, c->irssv))
        SvREFCNT_dec (c->irssv);
      else
        {
          REPLACE_SV (PL_rs, c->irssv);
          if (!c->irssv_sv) c->irssv_sv = get_sv ("/", 0);
          sv_setsv (c->irssv_sv, PL_rs);
        }
    }

  {
    dSP;
    CV *cv;

    /* now do the ugly restore mess */
    while ((cv = (CV *)POPs))
      {
        put_padlist (cv); /* mark this padlist as available */
        CvDEPTH (cv) = PTR2IV (POPs);
        CvPADLIST (cv) = (AV *)POPs;
      }

    PUTBACK;
  }
}

static void
save_perl (Coro__State c)
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

    EXTEND (SP, 3 + 1);
    PUSHs (Nullsv);
    /* this loop was inspired by pp_caller */
    for (;;)
      {
        while (cxix >= 0)
          {
            PERL_CONTEXT *cx = &ccstk[cxix--];

            if (CxTYPE (cx) == CXt_SUB)
              {
                CV *cv = cx->blk_sub.cv;

                if (CvDEPTH (cv))
                  {
                    EXTEND (SP, 3);
                    PUSHs ((SV *)CvPADLIST (cv));
                    PUSHs (INT2PTR (SV *, CvDEPTH (cv)));
                    PUSHs ((SV *)cv);

                    CvDEPTH (cv) = 0;
                    get_padlist (cv);
                  }
              }
          }

        if (top_si->si_type == PERLSI_MAIN)
          break;

        top_si = top_si->si_prev;
        ccstk = top_si->si_cxstack;
        cxix = top_si->si_cxix;
      }

    PUTBACK;
  }

  c->defav = c->save & CORO_SAVE_DEFAV ? (AV *)SvREFCNT_inc (GvAV (PL_defgv)) : 0;
  c->defsv = c->save & CORO_SAVE_DEFSV ?       SvREFCNT_inc (DEFSV)           : 0;
  c->errsv = c->save & CORO_SAVE_ERRSV ?       SvREFCNT_inc (ERRSV)           : 0;
  c->irssv = c->save & CORO_SAVE_IRSSV ?       SvREFCNT_inc (PL_rs)           : 0;

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
#if PREFER_PERL_FUNCTIONS
# define coro_init_stacks init_stacks
#else
static void
coro_init_stacks ()
{
    PL_curstackinfo = new_stackinfo(128, 1024/sizeof(PERL_CONTEXT));
    PL_curstackinfo->si_type = PERLSI_MAIN;
    PL_curstack = PL_curstackinfo->si_stack;
    PL_mainstack = PL_curstack;		/* remember in case we switch stacks */

    PL_stack_base = AvARRAY(PL_curstack);
    PL_stack_sp = PL_stack_base;
    PL_stack_max = PL_stack_base + AvMAX(PL_curstack);

    New(50,PL_tmps_stack,128,SV*);
    PL_tmps_floor = -1;
    PL_tmps_ix = -1;
    PL_tmps_max = 128;

    New(54,PL_markstack,32,I32);
    PL_markstack_ptr = PL_markstack;
    PL_markstack_max = PL_markstack + 32;

#ifdef SET_MARK_OFFSET
    SET_MARK_OFFSET;
#endif

    New(54,PL_scopestack,32,I32);
    PL_scopestack_ix = 0;
    PL_scopestack_max = 32;

    New(54,PL_savestack,64,ANY);
    PL_savestack_ix = 0;
    PL_savestack_max = 64;

#if !PERL_VERSION_ATLEAST (5,9,0)
    New(54,PL_retstack,16,OP*);
    PL_retstack_ix = 0;
    PL_retstack_max = 16;
#endif
}
#endif

/*
 * destroy the stacks, the callchain etc...
 */
static void
coro_destroy_stacks ()
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

/** coroutine stack handling ************************************************/

static void
setup_coro (struct coro *coro)
{
  /*
   * emulate part of the perl startup here.
   */

  coro_init_stacks ();

  PL_curcop     = &PL_compiling;
  PL_in_eval    = EVAL_NULL;
  PL_curpm      = 0;
  PL_localizing = 0;
  PL_dirty      = 0;
  PL_restartop  = 0;

  {
    dSP;
    LOGOP myop;

    SvREFCNT_dec (GvAV (PL_defgv));
    GvAV (PL_defgv) = coro->args; coro->args = 0;

    Zero (&myop, 1, LOGOP);
    myop.op_next = Nullop;
    myop.op_flags = OPf_WANT_VOID;

    PUSHMARK (SP);
    XPUSHs ((SV *)get_cv ("Coro::State::_coro_init", FALSE));
    PUTBACK;
    PL_op = (OP *)&myop;
    PL_op = PL_ppaddr[OP_ENTERSUB](aTHX);
    SPAGAIN;
  }

  ENTER; /* necessary e.g. for dounwind */
}

static void
free_coro_mortal ()
{
  if (coro_mortal)
    {
      SvREFCNT_dec (coro_mortal);
      coro_mortal = 0;
    }
}

/* inject a fake call to Coro::State::_cctx_init into the execution */
static void NOINLINE
prepare_cctx (coro_cctx *cctx)
{
  dSP;
  LOGOP myop;

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

static void
coro_run (void *arg)
{
  /* coro_run is the alternative tail of transfer(), so unlock here. */
  UNLOCK;

  /*
   * this is a _very_ stripped down perl interpreter ;)
   */
  PL_top_env = &PL_start_env;

  /* inject call to cctx_init */
  prepare_cctx ((coro_cctx *)arg);

  /* somebody will hit me for both perl_run and PL_restartop */
  PL_restartop = PL_op;
  perl_run (PL_curinterp);

  fputs ("FATAL: C coroutine fell over the edge of the world, aborting. Did you call exit in a coroutine?\n", stderr);
  abort ();
}

static coro_cctx *
cctx_new ()
{
  coro_cctx *cctx;

  ++cctx_count;

  Newz (0, cctx, 1, coro_cctx);

#if HAVE_MMAP

  cctx->ssize = ((STACKSIZE * sizeof (long) + PAGESIZE - 1) / PAGESIZE + STACKGUARD) * PAGESIZE;
  /* mmap supposedly does allocate-on-write for us */
  cctx->sptr = mmap (0, cctx->ssize, PROT_EXEC|PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, 0, 0);

  if (cctx->sptr != (void *)-1)
    {
# if STACKGUARD
      mprotect (cctx->sptr, STACKGUARD * PAGESIZE, PROT_NONE);
# endif
      REGISTER_STACK (
        cctx,
        STACKGUARD * PAGESIZE + (char *)cctx->sptr,
        cctx->ssize + (char *)cctx->sptr
      );

      coro_create (&cctx->cctx, coro_run, (void *)cctx, cctx->sptr, cctx->ssize);
    }
  else
#endif
    {
      cctx->ssize = -STACKSIZE * (long)sizeof (long);
      New (0, cctx->sptr, STACKSIZE, long);

      if (!cctx->sptr)
        {
          perror ("FATAL: unable to allocate stack for coroutine");
          _exit (EXIT_FAILURE);
        }

      REGISTER_STACK (
        cctx,
        (char *)cctx->sptr,
        (char *)cctx->sptr - cctx->ssize
      );

      coro_create (&cctx->cctx, coro_run, (void *)cctx, cctx->sptr, -cctx->ssize);
    }

  return cctx;
}

static void
cctx_destroy (coro_cctx *cctx)
{
  if (!cctx)
    return;

  --cctx_count;

#if USE_VALGRIND
  VALGRIND_STACK_DEREGISTER (cctx->valgrind_id);
#endif

#if HAVE_MMAP
  if (cctx->ssize > 0)
    munmap (cctx->sptr, cctx->ssize);
  else
#endif
    Safefree (cctx->sptr);

  Safefree (cctx);
}

static coro_cctx *
cctx_get ()
{
  coro_cctx *cctx;

  if (cctx_first)
    {
      cctx = cctx_first;
      cctx_first = cctx->next;
      --cctx_idle;
    }
  else
   {
     cctx = cctx_new ();
     PL_op = PL_op->op_next;
   }

  return cctx;
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

      assert (!first->inuse);
      cctx_destroy (first);
    }

  ++cctx_idle;
  cctx->next = cctx_first;
  cctx_first = cctx;
}

/** coroutine switching *****************************************************/

/* never call directly, always through the coro_state_transfer global variable */
static void NOINLINE
transfer (struct coro *prev, struct coro *next)
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
          prev->cctx->inuse = 1;
          prev->flags &= ~CF_NEW;
          prev->flags |=  CF_RUNNING;
        }

      /*TODO: must not croak here */
      if (!prev->flags & CF_RUNNING)
        croak ("Coro::State::transfer called with non-running prev Coro::State, but can only transfer from running states");

      if (next->flags & CF_RUNNING)
        croak ("Coro::State::transfer called with running next Coro::State, but can only transfer to inactive states");

      if (next->flags & CF_DESTROYED)
        croak ("Coro::State::transfer called with destroyed next Coro::State, but can only transfer to inactive states");

      prev->flags &= ~CF_RUNNING;
      next->flags |=  CF_RUNNING;

      LOCK;

      if (next->flags & CF_NEW)
        {
          /* need to start coroutine */
          next->flags &= ~CF_NEW;
          /* first get rid of the old state */
          save_perl (prev);
          /* setup coroutine call */
          setup_coro (next);
          /* need a new stack */
          assert (!next->cctx);
        }
      else
        {
          /* coroutine already started */
          save_perl (prev);
          load_perl (next);
        }

      prev__cctx = prev->cctx;

      /* possibly "free" the cctx */
      if (prev__cctx->idle_sp == STACKLEVEL)
        {
          /* I assume that STACKLEVEL is a stronger indicator than PL_top_env changes */
          assert (("ERROR: current top_env must equal previous top_env", PL_top_env == prev__cctx->idle_te));

          prev->cctx = 0;

          cctx_put (prev__cctx);
          prev__cctx->inuse = 0;
        }

      if (!next->cctx)
        {
          next->cctx = cctx_get ();
          assert (!next->cctx->inuse);
          next->cctx->inuse = 1;
        }

      if (prev__cctx != next->cctx)
        {
          prev__cctx->top_env = PL_top_env;
          PL_top_env = next->cctx->top_env;
          coro_transfer (&prev__cctx->cctx, &next->cctx->cctx);
        }

      free_coro_mortal ();
      UNLOCK;
    }
}

struct transfer_args
{
  struct coro *prev, *next;
};

#define TRANSFER(ta) transfer ((ta).prev, (ta).next)

/** high level stuff ********************************************************/

static int
coro_state_destroy (struct coro *coro)
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

      assert (!(coro->flags & CF_RUNNING));

      Zero (&temp, 1, struct coro);
      temp.save = CORO_SAVE_ALL;

      if (coro->flags & CF_RUNNING)
        croak ("FATAL: tried to destroy currently running coroutine");

      save_perl (&temp);
      load_perl (coro);

      coro_destroy_stacks ();

      load_perl (&temp); /* this will get rid of defsv etc.. */

      coro->mainstack = 0;
    }

  cctx_destroy (coro->cctx);
  SvREFCNT_dec (coro->args);

  return 1;
}

static int
coro_state_free (pTHX_ SV *sv, MAGIC *mg)
{
  struct coro *coro = (struct coro *)mg->mg_ptr;
  mg->mg_ptr = 0;

  if (--coro->refcnt < 0)
    {
      coro_state_destroy (coro);
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

static struct coro *
SvSTATE (SV *coro)
{
  HV *stash;
  MAGIC *mg;

  if (SvROK (coro))
    coro = SvRV (coro);

  stash = SvSTASH (coro);
  if (stash != coro_stash && stash != coro_state_stash)
    {
      /* very slow, but rare, check */
      if (!sv_derived_from (sv_2mortal (newRV_inc (coro)), "Coro::State"))
        croak ("Coro::State object required");
    }

  mg = SvMAGIC (coro);
  assert (mg->mg_type == PERL_MAGIC_ext);
  return (struct coro *)mg->mg_ptr;
}

static void
prepare_transfer (struct transfer_args *ta, SV *prev_sv, SV *next_sv)
{
  ta->prev = SvSTATE (prev_sv);
  ta->next = SvSTATE (next_sv);
}

static void
api_transfer (SV *prev_sv, SV *next_sv)
{
  struct transfer_args ta;

  prepare_transfer (&ta, prev_sv, next_sv);
  TRANSFER (ta);
}

static int
api_save (SV *coro_sv, int new_save)
{
  struct coro *coro = SvSTATE (coro_sv);
  int old_save = coro->save;

  if (new_save >= 0)
    coro->save = new_save;

  return old_save;
}

/** Coro ********************************************************************/

static void
coro_enq (SV *coro_sv)
{
  av_push (coro_ready [SvSTATE (coro_sv)->prio - PRIO_MIN], coro_sv);
}

static SV *
coro_deq (int min_prio)
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
  struct coro *coro;

  if (SvROK (coro_sv))
    coro_sv = SvRV (coro_sv);

  coro = SvSTATE (coro_sv);

  if (coro->flags & CF_READY)
    return 0;

  coro->flags |= CF_READY;

  LOCK;
  coro_enq (SvREFCNT_inc (coro_sv));
  ++coro_nready;
  UNLOCK;

  return 1;
}

static int
api_is_ready (SV *coro_sv)
{
  return !!(SvSTATE (coro_sv)->flags & CF_READY);
}

static void
prepare_schedule (struct transfer_args *ta)
{
  SV *prev_sv, *next_sv;

  for (;;)
    {
      LOCK;
      next_sv = coro_deq (PRIO_MIN);

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
  SvRV_set (coro_current, next_sv);
  ta->prev = SvSTATE (prev_sv);

  assert (ta->next->flags & CF_READY);
  ta->next->flags &= ~CF_READY;

  LOCK;
  free_coro_mortal ();
  coro_mortal = prev_sv;
  UNLOCK;
}

static void
prepare_cede (struct transfer_args *ta)
{
  api_ready (coro_current);
  prepare_schedule (ta);
}

static int
prepare_cede_notself (struct transfer_args *ta)
{
  if (coro_nready)
    {
      SV *prev = SvRV (coro_current);
      prepare_schedule (ta);
      api_ready (prev);
      return 1;
    }
  else
    return 0;
}

static void
api_schedule (void)
{
  struct transfer_args ta;

  prepare_schedule (&ta);
  TRANSFER (ta);
}

static int
api_cede (void)
{
  struct transfer_args ta;

  prepare_cede (&ta);

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
  struct transfer_args ta;

  if (prepare_cede_notself (&ta))
    {
      TRANSFER (ta);
      return 1;
    }
  else
    return 0;
}

MODULE = Coro::State                PACKAGE = Coro::State

PROTOTYPES: DISABLE

BOOT:
{
#ifdef USE_ITHREADS
        MUTEX_INIT (&coro_mutex);
#endif
        BOOT_PAGESIZE;

	coro_state_stash = gv_stashpv ("Coro::State", TRUE);

        newCONSTSUB (coro_state_stash, "SAVE_DEFAV", newSViv (CORO_SAVE_DEFAV));
        newCONSTSUB (coro_state_stash, "SAVE_DEFSV", newSViv (CORO_SAVE_DEFSV));
        newCONSTSUB (coro_state_stash, "SAVE_ERRSV", newSViv (CORO_SAVE_ERRSV));
        newCONSTSUB (coro_state_stash, "SAVE_IRSSV", newSViv (CORO_SAVE_IRSSV));
        newCONSTSUB (coro_state_stash, "SAVE_ALL",   newSViv (CORO_SAVE_ALL));

        main_mainstack = PL_mainstack;

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
        coro->args = newAV ();
        coro->save = CORO_SAVE_ALL;
        coro->flags = CF_NEW;

        hv = newHV ();
        sv_magicext ((SV *)hv, 0, PERL_MAGIC_ext, &coro_state_vtbl, (char *)coro, 0)->mg_flags |= MGf_DUP;
        RETVAL = sv_bless (newRV_noinc ((SV *)hv), gv_stashpv (klass, 1));

        for (i = 1; i < items; i++)
          av_push (coro->args, newSVsv (ST (i)));
}
        OUTPUT:
        RETVAL

int
save (SV *coro, int new_save = -1)
	CODE:
        RETVAL = api_save (coro, new_save);
	OUTPUT:
        RETVAL

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

              prepare_transfer (&ta, ST (0), ST (1));
              break;

            case 2:
              prepare_schedule (&ta);
              break;

            case 3:
              prepare_cede (&ta);
              break;

            case 4:
              if (!prepare_cede_notself (&ta))
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
	RETVAL = coro_state_destroy (SvSTATE (coro_sv));
	OUTPUT:
        RETVAL

void
_exit (code)
	int	code
        PROTOTYPE: $
	CODE:
	_exit (code);

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

MODULE = Coro::State                PACKAGE = Coro

BOOT:
{
	int i;

	coro_stash = gv_stashpv ("Coro",        TRUE);

        newCONSTSUB (coro_stash, "PRIO_MAX",    newSViv (PRIO_MAX));
        newCONSTSUB (coro_stash, "PRIO_HIGH",   newSViv (PRIO_HIGH));
        newCONSTSUB (coro_stash, "PRIO_NORMAL", newSViv (PRIO_NORMAL));
        newCONSTSUB (coro_stash, "PRIO_LOW",    newSViv (PRIO_LOW));
        newCONSTSUB (coro_stash, "PRIO_IDLE",   newSViv (PRIO_IDLE));
        newCONSTSUB (coro_stash, "PRIO_MIN",    newSViv (PRIO_MIN));

        coro_current = get_sv ("Coro::current", FALSE);
        SvREADONLY_on (coro_current);

        for (i = PRIO_MAX - PRIO_MIN + 1; i--; )
          coro_ready[i] = newAV ();

        {
          SV *sv = perl_get_sv("Coro::API", 1);

          coroapi.schedule     = api_schedule;
          coroapi.save         = api_save;
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

SV *
is_ready (SV *self)
        PROTOTYPE: $
	CODE:
        RETVAL = boolSV (api_is_ready (self));
	OUTPUT:
        RETVAL

int
nready (...)
	PROTOTYPE:
        CODE:
        RETVAL = coro_nready;
	OUTPUT:
        RETVAL

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

