#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "libcoro/coro.c"

#include <signal.h>

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
#endif

#define MAY_FLUSH /* increases codesize and is rarely used */

#define SUB_INIT    "Coro::State::initialize"
#define UCORO_STATE "_coro_state"

/* The next macro should declare a variable stacklevel that contains and approximation
 * to the current C stack pointer. Its property is that it changes with each call
 * and should be unique. */
#define dSTACKLEVEL void *stacklevel = &stacklevel

#define IN_DESTRUCT (PL_main_cv == Nullcv)

#define labs(l) ((l) >= 0 ? (l) : -(l))

#include "CoroAPI.h"

static struct CoroAPI coroapi;

/* this is actually not only the c stack but also c registers etc... */
typedef struct {
  int refcnt; /* pointer reference counter */
  int usecnt; /* shared by how many coroutines */
  int gencnt; /* generation counter */

  coro_context cctx;

  void *sptr;
  long ssize; /* positive == mmap, otherwise malloc */
} coro_stack;

struct coro {
  /* the optional C context */
  coro_stack *stack;
  void *cursp;
  int gencnt;

  /* optionally saved, might be zero */
  AV *defav;
  SV *defsv;
  SV *errsv;
  
  /* saved global state not related to stacks */
  U8 dowarn;
  I32 in_eval;

  /* the stacks and related info (callchain etc..) */
  PERL_SI *curstackinfo;
  AV *curstack;
  AV *mainstack;
  SV **stack_sp;
  OP *op;
  SV **curpad;
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
  COP *curcop;
  JMPENV *top_env;

  /* data associated with this coroutine (initial args) */
  AV *args;
};

typedef struct coro *Coro__State;
typedef struct coro *Coro__State_or_hashref;

static AV *main_mainstack; /* used to differentiate between $main and others */
static HV *coro_state_stash;
static SV *ucoro_state_sv;
static U32 ucoro_state_hash;
static HV *padlist_cache;

/* mostly copied from op.c:cv_clone2 */
STATIC AV *
clone_padlist (AV *protopadlist)
{
  AV *av;
  I32 ix;
  AV *protopad_name = (AV *) * av_fetch (protopadlist, 0, FALSE);
  AV *protopad = (AV *) * av_fetch (protopadlist, 1, FALSE);
  SV **pname = AvARRAY (protopad_name);
  SV **ppad = AvARRAY (protopad);
  I32 fname = AvFILLp (protopad_name);
  I32 fpad = AvFILLp (protopad);
  AV *newpadlist, *newpad_name, *newpad;
  SV **npad;

  newpad_name = newAV ();
  for (ix = fname; ix >= 0; ix--)
    av_store (newpad_name, ix, SvREFCNT_inc (pname[ix]));

  newpad = newAV ();
  av_fill (newpad, AvFILLp (protopad));
  npad = AvARRAY (newpad);

  newpadlist = newAV ();
  AvREAL_off (newpadlist);
  av_store (newpadlist, 0, (SV *) newpad_name);
  av_store (newpadlist, 1, (SV *) newpad);

  av = newAV ();                /* will be @_ */
  av_extend (av, 0);
  av_store (newpad, 0, (SV *) av);
  AvFLAGS (av) = AVf_REIFY;

  for (ix = fpad; ix > 0; ix--)
    {
      SV *namesv = (ix <= fname) ? pname[ix] : Nullsv;
      if (namesv && namesv != &PL_sv_undef)
        {
          char *name = SvPVX (namesv);        /* XXX */
          if (SvFLAGS (namesv) & SVf_FAKE || *name == '&')
            {                        /* lexical from outside? */
              npad[ix] = SvREFCNT_inc (ppad[ix]);
            }
          else
            {                        /* our own lexical */
              SV *sv;
              if (*name == '&')
                sv = SvREFCNT_inc (ppad[ix]);
              else if (*name == '@')
                sv = (SV *) newAV ();
              else if (*name == '%')
                sv = (SV *) newHV ();
              else
                sv = NEWSV (0, 0);
              if (!SvPADBUSY (sv))
                SvPADMY_on (sv);
              npad[ix] = sv;
            }
        }
      else if (IS_PADGV (ppad[ix]) || IS_PADCONST (ppad[ix]))
        {
          npad[ix] = SvREFCNT_inc (ppad[ix]);
        }
      else
        {
          SV *sv = NEWSV (0, 0);
          SvPADTMP_on (sv);
          npad[ix] = sv;
        }
    }

#if 0 /* return -ENOTUNDERSTOOD */
    /* Now that vars are all in place, clone nested closures. */

    for (ix = fpad; ix > 0; ix--) {
        SV* namesv = (ix <= fname) ? pname[ix] : Nullsv;
        if (namesv
            && namesv != &PL_sv_undef
            && !(SvFLAGS(namesv) & SVf_FAKE)
            && *SvPVX(namesv) == '&'
            && CvCLONE(ppad[ix]))
        {
            CV *kid = cv_clone((CV*)ppad[ix]);
            SvREFCNT_dec(ppad[ix]);
            CvCLONE_on(kid);
            SvPADMY_on(kid);
            npad[ix] = (SV*)kid;
        }
    }
#endif

  return newpadlist;
}

#ifdef MAY_FLUSH
STATIC void
free_padlist (AV *padlist)
{
  /* may be during global destruction */
  if (SvREFCNT(padlist))
    {
      I32 i = AvFILLp(padlist);
      while (i >= 0)
        {
          SV **svp = av_fetch(padlist, i--, FALSE);
          SV *sv = svp ? *svp : Nullsv;
          if (sv)
            SvREFCNT_dec(sv);
        }

      SvREFCNT_dec((SV*)padlist);
  }
}
#endif

/* the next two functions merely cache the padlists */
STATIC void
get_padlist (CV *cv)
{
  SV **he = hv_fetch (padlist_cache, (void *)&cv, sizeof (CV *), 0);

  if (he && AvFILLp ((AV *)*he) >= 0)
    CvPADLIST (cv) = (AV *)av_pop ((AV *)*he);
  else
    CvPADLIST (cv) = clone_padlist (CvPADLIST (cv));
}

STATIC void
put_padlist (CV *cv)
{
  SV **he = hv_fetch (padlist_cache, (void *)&cv, sizeof (CV *), 1);

  if (SvTYPE (*he) != SVt_PVAV)
    {
      SvREFCNT_dec (*he);
      *he = (SV *)newAV ();
    }

  av_push ((AV *)*he, (SV *)CvPADLIST (cv));
}

#ifdef MAY_FLUSH
STATIC void
flush_padlist_cache ()
{
  HV *hv = padlist_cache;
  padlist_cache = newHV ();

  if (hv_iterinit (hv))
    {
      HE *he;
      AV *padlist;

      while (!!(he = hv_iternext (hv)))
        {
          AV *av = (AV *)HeVAL(he);

          /* casting is fun. */
          while (&PL_sv_undef != (SV *)(padlist = (AV *)av_pop (av)))
            free_padlist (padlist);
        }
    }

  SvREFCNT_dec (hv);
}
#endif

#define SB do {
#define SE } while (0)

#define LOAD(state)       load_state(aTHX_ (state));
#define SAVE(state,flags) save_state(aTHX_ (state),(flags));

#define REPLACE_SV(sv,val) SB SvREFCNT_dec(sv); (sv) = (val); SE

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
  PL_retstack = c->retstack;
  PL_retstack_ix = c->retstack_ix;
  PL_retstack_max = c->retstack_max;
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
            put_padlist (cv); /* mark this padlist as available */
            CvPADLIST(cv) = padlist;
#ifdef USE_THREADS
            /*CvOWNER(cv) = (struct perl_thread *)POPs;*/
#endif
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
#ifdef USE_THREADS
                    /*XPUSHs ((SV *)CvOWNER(cv));*/
                    /*CvOWNER(cv) = 0;*/
                    /*error must unlock this cv etc.. etc...*/
#endif
                    EXTEND (SP, CvDEPTH(cv)*2);

                    while (--CvDEPTH(cv))
                      {
                        /* this tells the restore code to increment CvDEPTH */
                        PUSHs (Nullsv);
                        PUSHs ((SV *)cv);
                      }

                    PUSHs ((SV *)CvPADLIST(cv));
                    PUSHs ((SV *)cv);

                    get_padlist (cv); /* this is a monster */
                  }
              }
            else if (CxTYPE(cx) == CXt_FORMAT)
              {
                /* I never used formats, so how should I know how these are implemented? */
                /* my bold guess is as a simple, plain sub... */
                croak ("CXt_FORMAT not yet handled. Don't switch coroutines from within formats");
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
  c->retstack = PL_retstack;
  c->retstack_ix = PL_retstack_ix;
  c->retstack_max = PL_retstack_max;
  c->curcop = PL_curcop;
  c->top_env = PL_top_env;
}

/*
 * allocate various perl stacks. This is an exact copy
 * of perl.c:init_stacks, except that it uses less memory
 * on the assumption that coroutines do not usually need
 * a lot of stackspace.
 */
STATIC void
coro_init_stacks (pTHX)
{
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

    SET_MARK_OFFSET;

    New(54,PL_scopestack,16,I32);
    PL_scopestack_ix = 0;
    PL_scopestack_max = 16;

    New(54,PL_savestack,96,ANY);
    PL_savestack_ix = 0;
    PL_savestack_max = 96;

    New(54,PL_retstack,8,OP*);
    PL_retstack_ix = 0;
    PL_retstack_max = 8;
}

/*
 * destroy the stacks, the callchain etc...
 * still there is a memleak of 128 bytes...
 */
STATIC void
destroy_stacks(pTHX)
{
  if (!IN_DESTRUCT)
    {
      /* is this ugly, I ask? */
      while (PL_scopestack_ix)
        LEAVE;

      /* sure it is, but more important: is it correct?? :/ */
      while (PL_tmps_ix > PL_tmps_floor) /* should only ever be one iteration */
        FREETMPS;
    }

  while (PL_curstackinfo->si_next)
    PL_curstackinfo = PL_curstackinfo->si_next;

  while (PL_curstackinfo)
    {
      PERL_SI *p = PL_curstackinfo->si_prev;

      {
        dSP;
        SWITCHSTACK (PL_curstack, PL_curstackinfo->si_stack);
        PUTBACK; /* possibly superfluous */
      }

      if (!IN_DESTRUCT)
        {
          dounwind(-1);
          SvREFCNT_dec(PL_curstackinfo->si_stack);
        }

      Safefree(PL_curstackinfo->si_cxstack);
      Safefree(PL_curstackinfo);
      PL_curstackinfo = p;
  }

  Safefree(PL_tmps_stack);
  Safefree(PL_markstack);
  Safefree(PL_scopestack);
  Safefree(PL_savestack);
  Safefree(PL_retstack);
}

static void
allocate_stack (Coro__State ctx, int alloc)
{
  coro_stack *stack;

  New (0, stack, 1, coro_stack);

  stack->refcnt = 1;
  stack->usecnt = 1;
  stack->gencnt = ctx->gencnt = 0;
  if (alloc)
    {
#if HAVE_MMAP
      stack->ssize = 128 * 1024 * sizeof (long); /* mmap should do allocate-on-write for us */
      stack->sptr = mmap (0, stack->ssize, PROT_EXEC|PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, 0, 0);
      if (stack->sptr == (void *)-1)
#endif
        {
          /*FIXME*//*D*//* reasonable stack size! */
          stack->ssize = -4096 * sizeof (long);
          New (0, stack->sptr, 4096, long);
        }
    }
  else
    stack->sptr = 0;

  ctx->stack = stack;
}

static void
deallocate_stack (Coro__State ctx)
{
  coro_stack *stack = ctx->stack;

  ctx->stack = 0;

  if (stack)
    {
      if (!--stack->refcnt)
        {
#ifdef HAVE_MMAP
          if (stack->ssize > 0 && stack->sptr)
            munmap (stack->sptr, stack->ssize);
          else
#else
            Safefree (stack->sptr);
#endif
          Safefree (stack);
        }
      else if (ctx->gencnt == stack->gencnt)
        --stack->usecnt;
    }
}

static void
setup_coro (void *arg)
{
  /*
   * emulate part of the perl startup here.
   */
  dSP;
  Coro__State ctx = (Coro__State)arg;
  SV *sub_init = (SV*)get_cv(SUB_INIT, FALSE);

  coro_init_stacks (aTHX);
  /*PL_curcop = 0;*/
  /*PL_in_eval = PL_in_eval;*/ /* inherit */
  SvREFCNT_dec (GvAV (PL_defgv));
  GvAV (PL_defgv) = ctx->args;

  SPAGAIN;

  if (ctx->stack)
    {
      ctx->cursp = 0;

      PUSHMARK(SP);
      PUTBACK;
      (void) call_sv (sub_init, G_VOID|G_NOARGS|G_EVAL);

      if (SvTRUE (ERRSV))
        croak (NULL);
      else
        croak ("FATAL: CCTXT coroutine returned!");
    }
  else
    {
      UNOP myop;

      PL_op = (OP *)&myop;

      Zero(&myop, 1, UNOP);
      myop.op_next = Nullop;
      myop.op_flags = OPf_WANT_VOID;

      PUSHMARK(SP);
      XPUSHs (sub_init);
      /*
       * the next line is slightly wrong, as PL_op->op_next
       * is actually being executed so we skip the first op.
       * that doesn't matter, though, since it is only
       * pp_nextstate and we never return...
       * ah yes, and I don't care anyways ;)
       */
      PUTBACK;
      PL_op = pp_entersub();
      SPAGAIN;

      ENTER; /* necessary e.g. for dounwind */
    }
}

static void
continue_coro (void *arg)
{
  /*
   * this is a _very_ stripped down perl interpreter ;)
   */
  Coro__State ctx = (Coro__State)arg;
  JMPENV coro_start_env;

  /* same as JMPENV_BOOTSTRAP */
  Zero(&coro_start_env, 1, JMPENV);
  coro_start_env.je_ret = -1;
  coro_start_env.je_mustcatch = TRUE;
  PL_top_env = &coro_start_env;

  ctx->cursp = 0;
  PL_op = PL_op->op_next;
  CALLRUNOPS(aTHX);

  abort ();
}

STATIC void
transfer(pTHX_ struct coro *prev, struct coro *next, int flags)
{
  dSTACKLEVEL;
  static struct coro *xnext;

  if (prev != next)
    {
      xnext = next;

      if (next->mainstack)
        {
          SAVE (prev, flags);
          LOAD (next);

          /* mark this state as in-use */
          next->mainstack = 0;
          next->tmps_ix = -2;

          /* stacklevel changed? if yes, grab the stack for us! */
          if (flags & TRANSFER_SAVE_CCTXT)
            {
              if (!prev->stack)
                allocate_stack (prev, 0);
              else if (prev->cursp != stacklevel
                       && prev->stack->usecnt > 1)
                {
                  prev->gencnt = ++prev->stack->gencnt;
                  prev->stack->usecnt = 1;
                }

              /* has our stack been invalidated? */
              if (next->stack && next->stack->gencnt != next->gencnt)
                {
                  deallocate_stack (next);
                  allocate_stack (next, 1);
                  coro_create (&(next->stack->cctx),
                               continue_coro, (void *)next,
                               next->stack->sptr, labs (next->stack->ssize));
                }

              coro_transfer (&(prev->stack->cctx), &(next->stack->cctx));
              /* don't add any code here */
            }

        }
      else if (next->tmps_ix == -2)
        croak ("tried to transfer to running coroutine");
      else
        {
          SAVE (prev, -1); /* first get rid of the old state */

          if (flags & TRANSFER_SAVE_CCTXT)
            {
              if (!prev->stack)
                allocate_stack (prev, 0);

              if (prev->stack->sptr && flags & TRANSFER_LAZY_STACK)
                {
                  setup_coro (next);

                  prev->stack->refcnt++;
                  prev->stack->usecnt++;
                  next->stack = prev->stack;
                  next->gencnt = prev->gencnt;
                }
              else
                {
                  allocate_stack (next, 1);
                  coro_create (&(next->stack->cctx),
                               setup_coro, (void *)next,
                               next->stack->sptr, labs (next->stack->ssize));
                  coro_transfer (&(prev->stack->cctx), &(next->stack->cctx));
                  /* don't add any code here */
                }
            }
          else
            setup_coro (next);
        }

      /*
       * xnext is now either prev or next, depending on wether
       * we switched the c stack or not. that's why i use a global
       * variable, that should become thread-specific at one point.
       */
      xnext->cursp = stacklevel;
    }
}

static struct coro *
sv_to_coro (SV *arg, const char *funcname, const char *varname)
{
  if (SvROK(arg) && SvTYPE(SvRV(arg)) == SVt_PVHV)
    {
      HE *he = hv_fetch_ent((HV *)SvRV(arg), ucoro_state_sv, 0, ucoro_state_hash);

      if (!he)
        croak ("%s() -- %s is a hashref but lacks the " UCORO_STATE " key", funcname, varname);

      arg = HeVAL(he);
    }
     
  /* must also be changed inside Coro::Cont::yield */
  if (SvROK(arg) && SvOBJECT(SvRV(arg))
      && SvSTASH(SvRV(arg)) == coro_state_stash)
    return (struct coro *) SvIV((SV*)SvRV(arg));

  croak ("%s() -- %s is not (and contains not) a Coro::State object", funcname, varname);
  /*NORETURN*/
}

static void
api_transfer(pTHX_ SV *prev, SV *next, int flags)
{
  transfer(aTHX_
           sv_to_coro (prev, "Coro::transfer", "prev"),
           sv_to_coro (next, "Coro::transfer", "next"),
           flags);
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
static AV *coro_ready[PRIO_MAX-PRIO_MIN+1];
static int coro_nready;

static void
coro_enq (SV *sv)
{
  if (SvROK (sv))
    {
      SV *hv = SvRV (sv);
      if (SvTYPE (hv) == SVt_PVHV)
        {
          SV **xprio = hv_fetch ((HV *)hv, "prio", 4, 0);
          int prio = xprio ? SvIV (*xprio) : PRIO_NORMAL;

          prio = prio > PRIO_MAX ? PRIO_MAX
               : prio < PRIO_MIN ? PRIO_MIN
               : prio;

          av_push (coro_ready [prio - PRIO_MIN], sv);
          coro_nready++;

          return;
        }
    }

  croak ("Coro::ready tried to enqueue something that is not a coroutine");
}

static SV *
coro_deq (int min_prio)
{
  int prio = PRIO_MAX - PRIO_MIN;

  min_prio -= PRIO_MIN;
  if (min_prio < 0)
    min_prio = 0;

  for (prio = PRIO_MAX - PRIO_MIN + 1; --prio >= min_prio; )
    if (av_len (coro_ready[prio]) >= 0)
      {
        coro_nready--;
        return av_shift (coro_ready[prio]);
      }

  return 0;
}

static void
api_ready (SV *coro)
{
  coro_enq (SvREFCNT_inc (coro));
}

static void
api_schedule (int cede)
{
  SV *prev, *next;

  prev = GvSV (coro_current);

  if (cede)
    coro_enq (SvREFCNT_inc (prev));

  next = coro_deq (PRIO_MIN);

  if (!next)
    next = SvREFCNT_inc (GvSV (coro_idle));

  GvSV (coro_current) = SvREFCNT_inc (next);
  transfer (aTHX_
            sv_to_coro (prev, "Coro::schedule", "current coroutine"),
            sv_to_coro (next, "Coro::schedule", "next coroutine"),
            TRANSFER_SAVE_ALL | TRANSFER_LAZY_STACK);
  SvREFCNT_dec (next);
  SvREFCNT_dec (prev);
}

MODULE = Coro::State                PACKAGE = Coro::State

PROTOTYPES: ENABLE

BOOT:
{       /* {} necessary for stoopid perl-5.6.x */
        ucoro_state_sv = newSVpv (UCORO_STATE, sizeof(UCORO_STATE) - 1);
        PERL_HASH(ucoro_state_hash, UCORO_STATE, sizeof(UCORO_STATE) - 1);
	coro_state_stash = gv_stashpv ("Coro::State", TRUE);

        newCONSTSUB (coro_state_stash, "SAVE_DEFAV", newSViv (TRANSFER_SAVE_DEFAV));
        newCONSTSUB (coro_state_stash, "SAVE_DEFSV", newSViv (TRANSFER_SAVE_DEFSV));
        newCONSTSUB (coro_state_stash, "SAVE_ERRSV", newSViv (TRANSFER_SAVE_ERRSV));
        newCONSTSUB (coro_state_stash, "SAVE_CCTXT", newSViv (TRANSFER_SAVE_CCTXT));

	if (!padlist_cache)
	  padlist_cache = newHV ();

        main_mainstack = PL_mainstack;

        coroapi.ver      = CORO_API_VERSION;
        coroapi.transfer = api_transfer;
}

Coro::State
_newprocess(args)
        SV *	args
        PROTOTYPE: $
        CODE:
        Coro__State coro;

        if (!SvROK (args) || SvTYPE (SvRV (args)) != SVt_PVAV)
          croak ("Coro::State::_newprocess expects an arrayref");
        
        New (0, coro, 1, struct coro);

        coro->args = (AV *)SvREFCNT_inc (SvRV (args));
        coro->mainstack = 0; /* actual work is done inside transfer */
        coro->stack = 0;

        RETVAL = coro;
        OUTPUT:
        RETVAL

void
transfer(prev, next, flags)
        Coro::State_or_hashref	prev
        Coro::State_or_hashref	next
        int			flags
        PROTOTYPE: @
        CODE:
        PUTBACK;
        transfer (aTHX_ prev, next, flags);
        SPAGAIN;

void
DESTROY(coro)
        Coro::State	coro
        CODE:

        if (coro->mainstack && coro->mainstack != main_mainstack)
          {
            struct coro temp;

            PUTBACK;
            SAVE(aTHX_ (&temp), TRANSFER_SAVE_ALL);
            LOAD(aTHX_ coro);
            SPAGAIN;

            destroy_stacks (aTHX);

            LOAD((&temp)); /* this will get rid of defsv etc.. */
            SPAGAIN;

            coro->mainstack = 0;
          }

        deallocate_stack (coro);

        Safefree (coro);

void
flush()
	CODE:
#ifdef MAY_FLUSH
        flush_padlist_cache ();
#endif

void
_exit(code)
	int	code
        PROTOTYPE: $
	CODE:
#if defined(__GLIBC__) || _POSIX_C_SOURCE
	_exit (code);
#else
        signal (SIGTERM, SIG_DFL);
        raise (SIGTERM);
        exit (code);
#endif

MODULE = Coro::State                PACKAGE = Coro::Cont

# this is slightly dirty (should expose a c-level api)

void
yield(...)
	PROTOTYPE: @
        CODE:
        static SV *returnstk;
        SV *sv;
        AV *defav = GvAV (PL_defgv);
        struct coro *prev, *next;

        if (!returnstk)
          returnstk = SvRV (get_sv ("Coro::Cont::return", FALSE));

        /* set up @_ -- ugly */
        av_clear (defav);
        av_fill (defav, items - 1);
        while (items--)
          av_store (defav, items, SvREFCNT_inc (ST(items)));

        mg_get (returnstk); /* isn't documentation wrong for mg_get? */
        sv = av_pop ((AV *)SvRV (returnstk));
        prev = (struct coro *)SvIV ((SV*)SvRV (*av_fetch ((AV *)SvRV (sv), 0, 0)));
        next = (struct coro *)SvIV ((SV*)SvRV (*av_fetch ((AV *)SvRV (sv), 1, 0)));
        SvREFCNT_dec (sv);

        transfer(aTHX_ prev, next, 0);

MODULE = Coro::State                PACKAGE = Coro

# this is slightly dirty (should expose a c-level api)

BOOT:
{
	int i;
	HV *stash = gv_stashpv ("Coro", TRUE);

        newCONSTSUB (stash, "PRIO_MAX",    newSViv (PRIO_MAX));
        newCONSTSUB (stash, "PRIO_HIGH",   newSViv (PRIO_HIGH));
        newCONSTSUB (stash, "PRIO_NORMAL", newSViv (PRIO_NORMAL));
        newCONSTSUB (stash, "PRIO_LOW",    newSViv (PRIO_LOW));
        newCONSTSUB (stash, "PRIO_IDLE",   newSViv (PRIO_IDLE));
        newCONSTSUB (stash, "PRIO_MIN",    newSViv (PRIO_MIN));

        coro_current = gv_fetchpv ("Coro::current", TRUE, SVt_PV);
        coro_idle    = gv_fetchpv ("Coro::idle"   , TRUE, SVt_PV);

        for (i = PRIO_MAX - PRIO_MIN + 1; i--; )
          coro_ready[i] = newAV ();

        {
          SV *sv = perl_get_sv("Coro::API", 1);

          coroapi.schedule = api_schedule;
          coroapi.ready    = api_ready;
          coroapi.nready   = &coro_nready;
          coroapi.current  = coro_current;

          GCoroAPI = &coroapi;
          sv_setiv(sv, (IV)&coroapi);
          SvREADONLY_on(sv);
        }
}

void
ready(self)
	SV *	self
        PROTOTYPE: $
	CODE:
        api_ready (self);

int
nready(...)
	PROTOTYPE:
        CODE:
        RETVAL = coro_nready;
	OUTPUT:
        RETVAL

void
schedule(...)
	PROTOTYPE:
  	ALIAS:
           cede = 1
	CODE:
        api_schedule (ix);

