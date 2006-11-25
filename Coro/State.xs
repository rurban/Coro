#define PERL_NO_GET_CONTEXT

#include "libcoro/coro.c"

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "patchlevel.h"

#if PERL_VERSION < 6
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

#include <errno.h>

#if !__i386 && !__x86_64 && !__powerpc && !__m68k && !__alpha && !__mips && !__sparc64
# undef STACKGUARD
#endif

#ifndef STACKGUARD
# define STACKGUARD 0
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
#  define BOOT_PAGESIZE
# endif
#endif

#define SUB_INIT "Coro::State::initialize"

/* The next macro should declare a variable stacklevel that contains and approximation
 * to the current C stack pointer. Its property is that it changes with each call
 * and should be unique. */
#define dSTACKLEVEL void *stacklevel = &stacklevel

#define IN_DESTRUCT (PL_main_cv == Nullcv)

#define labs(l) ((l) >= 0 ? (l) : -(l))

#include "CoroAPI.h"

#ifdef USE_ITHREADS
static perl_mutex coro_mutex;
# define LOCK   do { MUTEX_LOCK   (&coro_mutex); } while (0)
# define UNLOCK do { MUTEX_UNLOCK (&coro_mutex); } while (0)
#else
# define LOCK   (void)0
# define UNLOCK (void)0
#endif

static struct CoroAPI coroapi;
static AV *main_mainstack; /* used to differentiate between $main and others */
static HV *coro_state_stash, *coro_stash;
static SV *coro_mortal; /* will be freed after next transfer */

/* this is actually not just the c stack but also c registers etc... */
typedef struct coro_stack {
  struct coro_stack *next;

  void *idle_sp;
  void *sptr;
  long ssize; /* positive == mmap, otherwise malloc */

  /* cpu state */
  coro_context cctx;
} coro_stack;

static coro_stack *main_stack;

struct coro {
  /* optionally saved, might be zero */
  AV *defav;
  SV *defsv;
  SV *errsv;
  
  /* saved global state not related to stacks */
  U8 dowarn;
  I32 in_eval;

  /* the c stack, if any */
  coro_stack *stack;

  /* the stacks and related info (callchain etc..) */
  PERL_SI *curstackinfo;
  AV *curstack;
  AV *mainstack;
  SV **stack_sp;
  OP *op;
  SV **curpad;
  AV *comppad;
  CV *compcv;
  SV **stack_base;
  SV **stack_max;
  SV **tmps_stack;
  I32 tmps_floor;
  I32 tmps_ix;
  I32 tmps_max;
  I32 *markstack;
  I32 *markstack_ptr;
  I32 *markstack_max;
  I32 *scopestack;
  I32 scopestack_ix;
  I32 scopestack_max;
  ANY *savestack;
  I32 savestack_ix;
  I32 savestack_max;
  OP **retstack;
  I32 retstack_ix;
  I32 retstack_max;
  PMOP *curpm;
  COP *curcop;
  JMPENV *top_env;

  /* coro process data */
  int prio;

  /* data associated with this coroutine (initial args) */
  AV *args;
  int refcnt;
};

typedef struct coro *Coro__State;
typedef struct coro *Coro__State_or_hashref;

static AV *
coro_clone_padlist (pTHX_ CV *cv)
{
  AV *padlist = CvPADLIST (cv);
  AV *newpadlist, *newpad;

  newpadlist = newAV ();
  AvREAL_off (newpadlist);
#if PERL_VERSION < 9
  Perl_pad_push (aTHX_ padlist, AvFILLp (padlist) + 1, 1);
#else
  Perl_pad_push (aTHX_ padlist, AvFILLp (padlist) + 1);
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

/* the next two functions merely cache the padlists */
static void
get_padlist (pTHX_ CV *cv)
{
  MAGIC *mg = mg_find ((SV *)cv, PERL_MAGIC_coro);

  if (mg && AvFILLp ((AV *)mg->mg_obj) >= 0)
    CvPADLIST (cv) = (AV *)av_pop ((AV *)mg->mg_obj);
  else
   {
#if 0
     /* this should work - but it doesn't :( */
     CV *cp = Perl_cv_clone (aTHX_ cv);
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
  MAGIC *mg = mg_find ((SV *)cv, PERL_MAGIC_coro);

  if (!mg)
    {
      sv_magic ((SV *)cv, 0, PERL_MAGIC_coro, 0, 0);
      mg = mg_find ((SV *)cv, PERL_MAGIC_coro);
      mg->mg_virtual = &vtbl_coro;
      mg->mg_obj = (SV *)newAV ();
    }

  av_push ((AV *)mg->mg_obj, (SV *)CvPADLIST (cv));
}

#define SB do {
#define SE } while (0)

#define LOAD(state)       load_state(aTHX_ (state));
#define SAVE(state,flags) save_state(aTHX_ (state),(flags));

#define REPLACE_SV(sv,val) SB SvREFCNT_dec(sv); (sv) = (val); (val) = 0; SE

static void
load_state(pTHX_ Coro__State c)
{
  PL_dowarn = c->dowarn;
  PL_in_eval = c->in_eval;

  PL_curstackinfo = c->curstackinfo;
  PL_curstack = c->curstack;
  PL_mainstack = c->mainstack;
  PL_stack_sp = c->stack_sp;
  PL_op = c->op;
  PL_curpad = c->curpad;
  PL_comppad = c->comppad;
  PL_compcv = c->compcv;
  PL_stack_base = c->stack_base;
  PL_stack_max = c->stack_max;
  PL_tmps_stack = c->tmps_stack;
  PL_tmps_floor = c->tmps_floor;
  PL_tmps_ix = c->tmps_ix;
  PL_tmps_max = c->tmps_max;
  PL_markstack = c->markstack;
  PL_markstack_ptr = c->markstack_ptr;
  PL_markstack_max = c->markstack_max;
  PL_scopestack = c->scopestack;
  PL_scopestack_ix = c->scopestack_ix;
  PL_scopestack_max = c->scopestack_max;
  PL_savestack = c->savestack;
  PL_savestack_ix = c->savestack_ix;
  PL_savestack_max = c->savestack_max;
#if PERL_VERSION < 9
  PL_retstack = c->retstack;
  PL_retstack_ix = c->retstack_ix;
  PL_retstack_max = c->retstack_max;
#endif
  PL_curpm = c->curpm;
  PL_curcop = c->curcop;
  PL_top_env = c->top_env;

  if (c->defav) REPLACE_SV (GvAV (PL_defgv), c->defav);
  if (c->defsv) REPLACE_SV (DEFSV          , c->defsv);
  if (c->errsv) REPLACE_SV (ERRSV          , c->errsv);

  {
    dSP;
    CV *cv;

    /* now do the ugly restore mess */
    while ((cv = (CV *)POPs))
      {
        AV *padlist = (AV *)POPs;

        if (padlist)
          {
            put_padlist (aTHX_ cv); /* mark this padlist as available */
            CvPADLIST(cv) = padlist;
          }

        ++CvDEPTH(cv);
      }

    PUTBACK;
  }
}

static void
save_state(pTHX_ Coro__State c, int flags)
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

    PUSHs (Nullsv);
    /* this loop was inspired by pp_caller */
    for (;;)
      {
        while (cxix >= 0)
          {
            PERL_CONTEXT *cx = &ccstk[cxix--];

            if (CxTYPE(cx) == CXt_SUB)
              {
                CV *cv = cx->blk_sub.cv;
                if (CvDEPTH(cv))
                  {
                    EXTEND (SP, CvDEPTH(cv)*2);

                    while (--CvDEPTH(cv))
                      {
                        /* this tells the restore code to increment CvDEPTH */
                        PUSHs (Nullsv);
                        PUSHs ((SV *)cv);
                      }

                    PUSHs ((SV *)CvPADLIST(cv));
                    PUSHs ((SV *)cv);

                    get_padlist (aTHX_ cv);
                  }
              }
#ifdef CXt_FORMAT
            else if (CxTYPE(cx) == CXt_FORMAT)
              {
                /* I never used formats, so how should I know how these are implemented? */
                /* my bold guess is as a simple, plain sub... */
                croak ("CXt_FORMAT not yet handled. Don't switch coroutines from within formats");
              }
#endif
          }

        if (top_si->si_type == PERLSI_MAIN)
          break;

        top_si = top_si->si_prev;
        ccstk = top_si->si_cxstack;
        cxix = top_si->si_cxix;
      }

    PUTBACK;
  }

  c->defav = flags & TRANSFER_SAVE_DEFAV ? (AV *)SvREFCNT_inc (GvAV (PL_defgv)) : 0;
  c->defsv = flags & TRANSFER_SAVE_DEFSV ?       SvREFCNT_inc (DEFSV)           : 0;
  c->errsv = flags & TRANSFER_SAVE_ERRSV ?       SvREFCNT_inc (ERRSV)           : 0;

  c->dowarn = PL_dowarn;
  c->in_eval = PL_in_eval;

  c->curstackinfo = PL_curstackinfo;
  c->curstack = PL_curstack;
  c->mainstack = PL_mainstack;
  c->stack_sp = PL_stack_sp;
  c->op = PL_op;
  c->curpad = PL_curpad;
  c->comppad = PL_comppad;
  c->compcv = PL_compcv;
  c->stack_base = PL_stack_base;
  c->stack_max = PL_stack_max;
  c->tmps_stack = PL_tmps_stack;
  c->tmps_floor = PL_tmps_floor;
  c->tmps_ix = PL_tmps_ix;
  c->tmps_max = PL_tmps_max;
  c->markstack = PL_markstack;
  c->markstack_ptr = PL_markstack_ptr;
  c->markstack_max = PL_markstack_max;
  c->scopestack = PL_scopestack;
  c->scopestack_ix = PL_scopestack_ix;
  c->scopestack_max = PL_scopestack_max;
  c->savestack = PL_savestack;
  c->savestack_ix = PL_savestack_ix;
  c->savestack_max = PL_savestack_max;
#if PERL_VERSION < 9
  c->retstack = PL_retstack;
  c->retstack_ix = PL_retstack_ix;
  c->retstack_max = PL_retstack_max;
#endif
  c->curpm = PL_curpm;
  c->curcop = PL_curcop;
  c->top_env = PL_top_env;
}

/*
 * allocate various perl stacks. This is an exact copy
 * of perl.c:init_stacks, except that it uses less memory
 * on the (sometimes correct) assumption that coroutines do
 * not usually need a lot of stackspace.
 */
static void
coro_init_stacks (pTHX)
{
    LOCK;

    PL_curstackinfo = new_stackinfo(96, 1024/sizeof(PERL_CONTEXT) - 1);
    PL_curstackinfo->si_type = PERLSI_MAIN;
    PL_curstack = PL_curstackinfo->si_stack;
    PL_mainstack = PL_curstack;		/* remember in case we switch stacks */

    PL_stack_base = AvARRAY(PL_curstack);
    PL_stack_sp = PL_stack_base;
    PL_stack_max = PL_stack_base + AvMAX(PL_curstack);

    New(50,PL_tmps_stack,96,SV*);
    PL_tmps_floor = -1;
    PL_tmps_ix = -1;
    PL_tmps_max = 96;

    New(54,PL_markstack,16,I32);
    PL_markstack_ptr = PL_markstack;
    PL_markstack_max = PL_markstack + 16;

#ifdef SET_MARK_OFFSET
    SET_MARK_OFFSET;
#endif

    New(54,PL_scopestack,16,I32);
    PL_scopestack_ix = 0;
    PL_scopestack_max = 16;

    New(54,PL_savestack,96,ANY);
    PL_savestack_ix = 0;
    PL_savestack_max = 96;

#if PERL_VERSION < 9
    New(54,PL_retstack,8,OP*);
    PL_retstack_ix = 0;
    PL_retstack_max = 8;
#endif

    UNLOCK;
}

/*
 * destroy the stacks, the callchain etc...
 */
static void
destroy_stacks(pTHX)
{
  if (!IN_DESTRUCT)
    {
      /* is this ugly, I ask? */
      LEAVE_SCOPE (0);

      /* sure it is, but more important: is it correct?? :/ */
      FREETMPS;

      /*POPSTACK_TO (PL_mainstack);*//*D*//*use*/
    }

  while (PL_curstackinfo->si_next)
    PL_curstackinfo = PL_curstackinfo->si_next;

  while (PL_curstackinfo)
    {
      PERL_SI *p = PL_curstackinfo->si_prev;

      { /*D*//*remove*/
        dSP;
        SWITCHSTACK (PL_curstack, PL_curstackinfo->si_stack);
        PUTBACK; /* possibly superfluous */
      }

      if (!IN_DESTRUCT)
        {
          dounwind (-1);/*D*//*remove*/
          SvREFCNT_dec (PL_curstackinfo->si_stack);
        }

      Safefree (PL_curstackinfo->si_cxstack);
      Safefree (PL_curstackinfo);
      PL_curstackinfo = p;
  }

  Safefree (PL_tmps_stack);
  Safefree (PL_markstack);
  Safefree (PL_scopestack);
  Safefree (PL_savestack);
#if PERL_VERSION < 9
  Safefree (PL_retstack);
#endif
}

static void
setup_coro (struct coro *coro)
{
  /*
   * emulate part of the perl startup here.
   */
  dTHX;
  dSP;
  UNOP myop;
  SV *sub_init = (SV *)get_cv (SUB_INIT, FALSE);

  coro_init_stacks (aTHX);
  /*PL_curcop = 0;*/
  /*PL_in_eval = PL_in_eval;*/ /* inherit */
  SvREFCNT_dec (GvAV (PL_defgv));
  GvAV (PL_defgv) = coro->args; coro->args = 0;

  SPAGAIN;

  Zero (&myop, 1, UNOP);
  myop.op_next = Nullop;
  myop.op_flags = OPf_WANT_VOID;

  PL_op = (OP *)&myop;

  PUSHMARK(SP);
  XPUSHs (sub_init);
  PUTBACK;
  PL_op = PL_ppaddr[OP_ENTERSUB](aTHX);
  SPAGAIN;

  ENTER; /* necessary e.g. for dounwind */
}

static void
transfer_tail ()
{
  if (coro_mortal)
    {
      SvREFCNT_dec (coro_mortal);
      coro_mortal = 0;
    }

  UNLOCK;
}

static void
coro_run (void *arg)
{
  /*
   * this is a _very_ stripped down perl interpreter ;)
   */
  dTHX;

  transfer_tail ();

  PL_top_env = &PL_start_env;
  PL_restartop = PL_op;
  /* somebody will hit me for both perl_run and PL_restart_top */
  perl_run (aTHX_ PERL_GET_CONTEXT);

  abort ();
}

static coro_stack *
stack_new ()
{
  coro_stack *stack;

  New (0, stack, 1, coro_stack);

#if HAVE_MMAP

  stack->ssize = ((STACKSIZE * sizeof (long) + PAGESIZE - 1) / PAGESIZE + STACKGUARD) * PAGESIZE; /* mmap should do allocate-on-write for us */
  stack->sptr = mmap (0, stack->ssize, PROT_EXEC|PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, 0, 0);

  if (stack->sptr == (void *)-1)
    {
      fprintf (stderr, "FATAL: unable to mmap stack for coroutine\n");
      _exit (EXIT_FAILURE);
    }

  mprotect (stack->sptr, STACKGUARD * PAGESIZE, PROT_NONE);

#else

  stack->ssize = STACKSIZE * (long)sizeof (long);
  New (0, stack->sptr, STACKSIZE, long);

  if (!stack->sptr)
    {
      fprintf (stderr, "FATAL: unable to malloc stack for coroutine\n");
      _exit (EXIT_FAILURE);
    }

#endif

  coro_create (&stack->cctx, coro_run, 0, stack->sptr, stack->ssize);

  return stack;
}

static void
stack_free (coro_stack *stack)
{
  if (!stack || stack == main_stack)
    return;

#if HAVE_MMAP
  munmap (stack->sptr, stack->ssize);
#else
  Safefree (stack->sptr);
#endif

  Safefree (stack);
}

static coro_stack *stack_first;

static coro_stack *
stack_get ()
{
  coro_stack *stack;

  if (stack_first)
    {
      stack = stack_first;
      stack_first = stack->next;
    }
  else
   {
     stack = stack_new ();
     PL_op = PL_op->op_next;
   }

  return stack;
}

static void
stack_put (coro_stack *stack)
{
  stack->next = stack_first;
  stack_first = stack;
}

/* never call directly, always through the coro_state_transfer global variable */
static void
transfer_impl (pTHX_ struct coro *prev, struct coro *next, int flags)
{
  dSTACKLEVEL;

  /* sometimes transfer is only called to set idle_sp */
  if (!prev->stack->idle_sp)
    prev->stack->idle_sp = stacklevel;

  LOCK;

  if (prev != next)
    {
      coro_stack *prev_stack = prev->stack;

      /* possibly "free" the stack */
      if (0 && prev_stack->idle_sp == stacklevel)
        {
          stack_put (prev_stack);
          prev->stack = 0;
        }

      if (next->mainstack)
        {
          /* coroutine already started */
          SAVE (prev, flags);
          LOAD (next);
        }
      else
        {
          /* need to start coroutine */
          /* first get rid of the old state */
          SAVE (prev, -1);
          /* setup coroutine call */
          setup_coro (next);
          /* need to change stack from main_stack to real one */
          next->stack = 0;
        }

      if (!next->stack)
        next->stack = stack_get ();

      if (prev_stack != next->stack)
        coro_transfer (&prev_stack->cctx, &next->stack->cctx);
    }

  transfer_tail ();
}

/* use this function pointer to call the above function */
/* this is done to increase chances of the compiler not inlining the call */
void (*coro_state_transfer)(pTHX_ struct coro *prev, struct coro *next, int flags) = transfer_impl;

static void
coro_state_destroy (struct coro *coro)
{
  if (coro->refcnt--)
    return;

  if (coro->mainstack && coro->mainstack != main_mainstack)
    {
      struct coro temp;

      SAVE (aTHX_ (&temp), TRANSFER_SAVE_ALL);
      LOAD (aTHX_ coro);

      destroy_stacks (aTHX);

      LOAD ((&temp)); /* this will get rid of defsv etc.. */

      coro->mainstack = 0;
    }

  stack_free (coro->stack);
  SvREFCNT_dec (coro->args);
  Safefree (coro);
}

static int
coro_state_clear (SV *sv, MAGIC *mg)
{
  struct coro *coro = (struct coro *)mg->mg_ptr;
  mg->mg_ptr = 0;

  coro_state_destroy (coro);

  return 0;
}

static int
coro_state_dup (MAGIC *mg, CLONE_PARAMS *params)
{
  struct coro *coro = (struct coro *)mg->mg_ptr;

  ++coro->refcnt;

  return 0;
}

static MGVTBL coro_state_vtbl = { 0, 0, 0, 0, coro_state_clear, 0, coro_state_dup, 0 };

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
api_transfer (pTHX_ SV *prev, SV *next, int flags)
{
  coro_state_transfer (aTHX_ SvSTATE (prev), SvSTATE (next), flags);
}

/** Coro ********************************************************************/

#define PRIO_MAX     3
#define PRIO_HIGH    1
#define PRIO_NORMAL  0
#define PRIO_LOW    -1
#define PRIO_IDLE   -3
#define PRIO_MIN    -4

/* for Coro.pm */
static GV *coro_current, *coro_idle;
static AV *coro_ready [PRIO_MAX-PRIO_MIN+1];
static int coro_nready;

static void
coro_enq (pTHX_ SV *sv)
{
  int prio;

  if (SvTYPE (sv) != SVt_PVHV)
    croak ("Coro::ready tried to enqueue something that is not a coroutine");

  prio = SvSTATE (sv)->prio;

  av_push (coro_ready [prio - PRIO_MIN], sv);
  coro_nready++;
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
      {
        coro_nready--;
        return av_shift (coro_ready [prio]);
      }

  return 0;
}

static void
api_ready (SV *coro)
{
  dTHX;

  if (SvROK (coro))
    coro = SvRV (coro);

  LOCK;
  coro_enq (aTHX_ SvREFCNT_inc (coro));
  UNLOCK;
}

static void
api_schedule (void)
{
  dTHX;

  SV *prev, *next;
  SV *current = GvSV (coro_current);

  for (;;)
    {
      LOCK;

      next = coro_deq (aTHX_ PRIO_MIN);

      if (next)
        break;

      UNLOCK;

      {
        dSP;

        ENTER;
        SAVETMPS;

        PUSHMARK (SP);
        PUTBACK;
        call_sv (GvSV (coro_idle), G_DISCARD);

        FREETMPS;
        LEAVE;
      }
    }

  prev = SvRV (current);
  SvRV (current) = next;

  /* free this only after the transfer */
  coro_mortal = prev;

  UNLOCK;

  coro_state_transfer (aTHX_ SvSTATE (prev), SvSTATE (next), TRANSFER_SAVE_ALL);
}

static int coro_cede_self;

static void
api_cede (void)
{
  dTHX;
  SV *current = SvREFCNT_inc (SvRV (GvSV (coro_current)));

  LOCK;

  if (coro_cede_self)
    {
      AV *runqueue = coro_ready [PRIO_MAX - PRIO_MIN];
      av_unshift (runqueue, 1);
      av_store (runqueue, 0, current);
      coro_nready++;
      coro_cede_self = 0;
    }
  else
    coro_enq (aTHX_ current);

  UNLOCK;

  api_schedule ();
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

        newCONSTSUB (coro_state_stash, "SAVE_DEFAV", newSViv (TRANSFER_SAVE_DEFAV));
        newCONSTSUB (coro_state_stash, "SAVE_DEFSV", newSViv (TRANSFER_SAVE_DEFSV));
        newCONSTSUB (coro_state_stash, "SAVE_ERRSV", newSViv (TRANSFER_SAVE_ERRSV));

        main_mainstack = PL_mainstack;

        coroapi.ver      = CORO_API_VERSION;
        coroapi.transfer = api_transfer;

        Newz (0, main_stack, 1, coro_stack);
        main_stack->idle_sp = (void *)-1;

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

        hv = newHV ();
        sv_magicext ((SV *)hv, 0, PERL_MAGIC_ext, &coro_state_vtbl, (char *)coro, 0)->mg_flags |= MGf_DUP;
        RETVAL = sv_bless (newRV_noinc ((SV *)hv), gv_stashpv (klass, 1));

        av_push (coro->args, newSVsv (RETVAL));
        for (i = 1; i < items; i++)
          av_push (coro->args, newSVsv (ST (i)));

        coro->stack = main_stack;
        /*coro->mainstack = 0; *//*actual work is done inside transfer */
        /*coro->stack = 0;*/
}
        OUTPUT:
        RETVAL

void
transfer (prev, next, flags)
        SV	*prev
        SV	*next
        int	flags
        CODE:
        PUTBACK;
        coro_state_transfer (aTHX_ SvSTATE (prev), SvSTATE (next), flags);
        SPAGAIN;

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
              newprio += coro->prio;

            if (newprio < PRIO_MIN) newprio = PRIO_MIN;
            if (newprio > PRIO_MAX) newprio = PRIO_MAX;

            coro->prio = newprio;
          }
}

void
_clear_idle_sp (Coro::State self)
	CODE:
        self->stack->idle_sp = 0;

void
_clone_state_from (SV *dst, SV *src)
	CODE:
{
	struct coro *coro_src = SvSTATE (src);

        sv_unmagic (SvRV (dst), PERL_MAGIC_ext);

        ++coro_src->refcnt;
        sv_magicext (SvRV (dst), 0, PERL_MAGIC_ext, &coro_state_vtbl, (char *)coro_src, 0)->mg_flags |= MGf_DUP;
}

void
_exit (code)
	int	code
        PROTOTYPE: $
	CODE:
	_exit (code);

MODULE = Coro::State                PACKAGE = Coro::Cont

void
yield (...)
	PROTOTYPE: @
        CODE:
{
        SV *yieldstack;
        SV *sv;
        AV *defav = GvAV (PL_defgv);
        struct coro *prev, *next;

        yieldstack = *hv_fetch (
           (HV *)SvRV (GvSV (coro_current)),
           "yieldstack", sizeof ("yieldstack") - 1,
           0
        );

        /* set up @_ -- ugly */
        av_clear (defav);
        av_fill (defav, items - 1);
        while (items--)
          av_store (defav, items, SvREFCNT_inc (ST(items)));

        sv = av_pop ((AV *)SvRV (yieldstack));
        prev = SvSTATE (*av_fetch ((AV *)SvRV (sv), 0, 0));
        next = SvSTATE (*av_fetch ((AV *)SvRV (sv), 1, 0));
        SvREFCNT_dec (sv);

        coro_state_transfer (aTHX_ prev, next, 0);
}

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

        coro_current = gv_fetchpv ("Coro::current", TRUE, SVt_PV);
        coro_idle    = gv_fetchpv ("Coro::idle"   , TRUE, SVt_PV);

        for (i = PRIO_MAX - PRIO_MIN + 1; i--; )
          coro_ready[i] = newAV ();

        {
          SV *sv = perl_get_sv("Coro::API", 1);

          coroapi.schedule = api_schedule;
          coroapi.cede     = api_cede;
          coroapi.ready    = api_ready;
          coroapi.nready   = &coro_nready;
          coroapi.current  = coro_current;

          GCoroAPI = &coroapi;
          sv_setiv (sv, (IV)&coroapi);
          SvREADONLY_on (sv);
        }
}

void
ready (SV *self)
        PROTOTYPE: $
	CODE:
        api_ready (self);

int
nready (...)
	PROTOTYPE:
        CODE:
        RETVAL = coro_nready;
	OUTPUT:
        RETVAL

void
schedule (...)
	PROTOTYPE:
	CODE:
        api_schedule ();

void
_set_cede_self ()
	CODE:
        coro_cede_self = 1;

void
cede (...)
	PROTOTYPE:
	CODE:
        api_cede ();

MODULE = Coro::State                PACKAGE = Coro::AIO

SV *
_get_state ()
	CODE:
{
	struct {
          int errorno;
          int laststype;
          int laststatval;
          Stat_t statcache;
        } data;

        data.errorno = errno;
        data.laststype = PL_laststype;
        data.laststatval = PL_laststatval;
        data.statcache = PL_statcache;

        RETVAL = newSVpvn ((char *)&data, sizeof data);
}
	OUTPUT:
        RETVAL

void
_set_state (char *data_)
	PROTOTYPE: $
	CODE:
{
	struct {
          int errorno;
          int laststype;
          int laststatval;
          Stat_t statcache;
        } *data = (void *)data_;

        errno = data->errorno;
        PL_laststype = data->laststype;
        PL_laststatval = data->laststatval;
        PL_statcache = data->statcache;
}
