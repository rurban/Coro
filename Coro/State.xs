#define PERL_NO_GET_CONTEXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "patchlevel.h"

#if PATCHLEVEL < 6
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

#define SUB_INIT    "Coro::State::initialize"
#define UCORO_STATE "_coro_state"

/* The next macro should declare a variable stacklevel that contains and approximation
 * to the current C stack pointer. Its property is that it changes with each call
 * and should be unique. */
#define dSTACKLEVEL void *stacklevel = &stacklevel

#define IN_DESTRUCT (PL_main_cv == Nullcv)

#define labs(l) ((l) >= 0 ? (l) : -(l))

#include "CoroAPI.h"

#ifdef USE_ITHREADS
static perl_mutex coro_mutex;
# define LOCK   do { MUTEX_LOCK (&coro_mutex);   } while (0)
# define UNLOCK do { MUTEX_UNLOCK (&coro_mutex); } while (0)
#else
# define LOCK   0
# define UNLOCK 0
#endif

static struct CoroAPI coroapi;
static AV *main_mainstack; /* used to differentiate between $main and others */
static HV *coro_state_stash;
static SV *ucoro_state_sv;
static U32 ucoro_state_hash;
static SV *coro_mortal; /* will be freed after next transfer */

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
  /* the top-level JMPENV for each coroutine, needed to catch dies. */
  JMPENV start_env;

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
  AV *comppad;
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

/* mostly copied from op.c:cv_clone2 */
STATIC AV *
clone_padlist (pTHX_ AV *protopadlist)
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

#ifdef SvPADBUSY
              if (!SvPADBUSY (sv))
#endif
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

STATIC void
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

STATIC int
coro_cv_free (pTHX_ SV *sv, MAGIC *mg)
{
  AV *padlist;
  AV *av = (AV *)mg->mg_obj;

  /* casting is fun. */
  while (&PL_sv_undef != (SV *)(padlist = (AV *)av_pop (av)))
    free_padlist (aTHX_ padlist);

  SvREFCNT_dec (av);
}

#define PERL_MAGIC_coro PERL_MAGIC_ext

static MGVTBL vtbl_coro = {0, 0, 0, 0, coro_cv_free};

/* the next two functions merely cache the padlists */
STATIC void
get_padlist (pTHX_ CV *cv)
{
  MAGIC *mg = mg_find ((SV *)cv, PERL_MAGIC_coro);

  if (mg && AvFILLp ((AV *)mg->mg_obj) >= 0)
    CvPADLIST (cv) = (AV *)av_pop ((AV *)mg->mg_obj);
  else
    CvPADLIST (cv) = clone_padlist (aTHX_ CvPADLIST (cv));
}

STATIC void
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

                    get_padlist (aTHX_ cv); /* this is a monster */
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
 * on the (sometimes correct) assumption that coroutines do
 * not usually need a lot of stackspace.
 */
STATIC void
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

    New(54,PL_retstack,8,OP*);
    PL_retstack_ix = 0;
    PL_retstack_max = 8;

    UNLOCK;
}

/*
 * destroy the stacks, the callchain etc...
 */
STATIC void
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
  Safefree (PL_retstack);
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
      stack->ssize = 16384 * sizeof (long); /* mmap should do allocate-on-write for us */
      stack->sptr = mmap (0, stack->ssize, PROT_EXEC|PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, 0, 0);
      if (stack->sptr == (void *)-1)
#endif
        {
          /*FIXME*//*D*//* reasonable stack size! */
          stack->ssize = - (8192 * sizeof (long));
          New (0, stack->sptr, 8192, long);
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
#endif
            Safefree (stack->sptr);

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
  dTHX;
  dSP;
  Coro__State ctx = (Coro__State)arg;
  SV *sub_init = (SV *)get_cv (SUB_INIT, FALSE);

  coro_init_stacks (aTHX);
  /*PL_curcop = 0;*/
  /*PL_in_eval = PL_in_eval;*/ /* inherit */
  SvREFCNT_dec (GvAV (PL_defgv));
  GvAV (PL_defgv) = ctx->args; ctx->args = 0;

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
      PL_op = PL_ppaddr[OP_ENTERSUB](aTHX);
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
  dTHX;
  Coro__State ctx = (Coro__State)arg;
  JMPENV coro_start_env;

  PL_top_env = &ctx->start_env;

  ctx->cursp = 0;
  PL_op = PL_op->op_next;
  CALLRUNOPS(aTHX);

  abort ();
}

STATIC void
transfer (pTHX_ struct coro *prev, struct coro *next, int flags)
{
  dSTACKLEVEL;

  if (prev != next)
    {
      if (next->mainstack)
        {
          LOCK;
          SAVE (prev, flags);
          LOAD (next);
          UNLOCK;

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
              prev->cursp = stacklevel;
              /* don't add any code here */
            }
          else
            next->cursp = stacklevel;
        }
      else if (next->tmps_ix == -2)
        croak ("tried to transfer to running coroutine");
      else
        {
          LOCK;
          SAVE (prev, -1); /* first get rid of the old state */
          UNLOCK;

          if (flags & TRANSFER_SAVE_CCTXT)
            {
              if (!prev->stack)
                allocate_stack (prev, 0);

              if (prev->stack->sptr && flags & TRANSFER_LAZY_STACK)
                {
                  PL_top_env = &next->start_env;

                  setup_coro (next);
                  next->cursp = stacklevel;

                  prev->stack->refcnt++;
                  prev->stack->usecnt++;
                  next->stack = prev->stack;
                  next->gencnt = prev->gencnt;
                }
              else
                {
                  assert (!next->stack);
                  allocate_stack (next, 1);
                  coro_create (&(next->stack->cctx),
                               setup_coro, (void *)next,
                               next->stack->sptr, labs (next->stack->ssize));
                  coro_transfer (&(prev->stack->cctx), &(next->stack->cctx));
                  prev->cursp = stacklevel;
                  /* don't add any code here */
                }
            }
          else
            {
              setup_coro (next);
              next->cursp = stacklevel;
            }
        }
    }

  LOCK;
  if (coro_mortal)
    {
      SvREFCNT_dec (coro_mortal);
      coro_mortal = 0;
    }
  UNLOCK;
}

#define SV_CORO(sv,func)									\
  do {												\
    if (SvROK (sv))										\
      sv = SvRV (sv);										\
        											\
    if (SvTYPE (sv) == SVt_PVHV)								\
      {												\
        HE *he = hv_fetch_ent ((HV *)sv, ucoro_state_sv, 0, ucoro_state_hash);			\
												\
        if (!he)										\
          croak ("%s() -- %s is a hashref but lacks the " UCORO_STATE " key", func, # sv);	\
                                                                                                \
        (sv) = SvRV (HeVAL(he));								\
      }												\
                                                                                                \
    /* must also be changed inside Coro::Cont::yield */						\
    if (!SvOBJECT (sv) || SvSTASH (sv) != coro_state_stash)					\
      croak ("%s() -- %s is not (and contains not) a Coro::State object", func, # sv);		\
												\
  } while(0)

#define SvSTATE(sv) (struct coro *)SvIV (sv)

static void
api_transfer(pTHX_ SV *prev, SV *next, int flags)
{
  SV_CORO (prev, "Coro::transfer");
  SV_CORO (next, "Coro::transfer");

  transfer (aTHX_ SvSTATE (prev), SvSTATE (next), flags);
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
coro_enq (pTHX_ SV *sv)
{
  if (SvTYPE (sv) == SVt_PVHV)
    {
      SV **xprio = hv_fetch ((HV *)sv, "prio", 4, 0);
      int prio = xprio ? SvIV (*xprio) : PRIO_NORMAL;

      prio = prio > PRIO_MAX ? PRIO_MAX
           : prio < PRIO_MIN ? PRIO_MIN
           : prio;

      av_push (coro_ready [prio - PRIO_MIN], sv);
      coro_nready++;

      return;
    }

  croak ("Coro::ready tried to enqueue something that is not a coroutine");
}

static SV *
coro_deq (pTHX_ int min_prio)
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

  LOCK;

  prev = SvRV (GvSV (coro_current));
  next = coro_deq (aTHX_ PRIO_MIN);

  if (!next)
    next = SvREFCNT_inc (SvRV (GvSV (coro_idle)));

  /* free this only after the transfer */
  coro_mortal = prev;
  SV_CORO (prev, "Coro::schedule");

  SvRV (GvSV (coro_current)) = next;

  SV_CORO (next, "Coro::schedule");

  UNLOCK;

  transfer (aTHX_ SvSTATE (prev), SvSTATE (next),
            TRANSFER_SAVE_ALL | TRANSFER_LAZY_STACK);
}

static void
api_cede (void)
{
  dTHX;

  LOCK;
  coro_enq (aTHX_ SvREFCNT_inc (SvRV (GvSV (coro_current))));
  UNLOCK;

  api_schedule ();
}

MODULE = Coro::State                PACKAGE = Coro::State

PROTOTYPES: ENABLE

BOOT:
{       /* {} necessary for stoopid perl-5.6.x */
#ifdef USE_ITHREADS
        MUTEX_INIT (&coro_mutex);
#endif

        ucoro_state_sv = newSVpv (UCORO_STATE, sizeof(UCORO_STATE) - 1);
        PERL_HASH(ucoro_state_hash, UCORO_STATE, sizeof(UCORO_STATE) - 1);
	coro_state_stash = gv_stashpv ("Coro::State", TRUE);

        newCONSTSUB (coro_state_stash, "SAVE_DEFAV", newSViv (TRANSFER_SAVE_DEFAV));
        newCONSTSUB (coro_state_stash, "SAVE_DEFSV", newSViv (TRANSFER_SAVE_DEFSV));
        newCONSTSUB (coro_state_stash, "SAVE_ERRSV", newSViv (TRANSFER_SAVE_ERRSV));
        newCONSTSUB (coro_state_stash, "SAVE_CCTXT", newSViv (TRANSFER_SAVE_CCTXT));

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
        
        Newz (0, coro, 1, struct coro);

        coro->args = (AV *)SvREFCNT_inc (SvRV (args));
        /*coro->mainstack = 0; *//*actual work is done inside transfer */
        /*coro->stack = 0;*/

        /* same as JMPENV_BOOTSTRAP */
        /* we might be able to recycle start_env, but safe is safe */
        /*Zero(&coro->start_env, 1, JMPENV);*/
        coro->start_env.je_ret = -1;
        coro->start_env.je_mustcatch = TRUE;

        RETVAL = coro;
        OUTPUT:
        RETVAL

void
transfer(prev, next, flags)
        SV	*prev
        SV	*next
        int	flags
        PROTOTYPE: @
        CODE:
        PUTBACK;
        SV_CORO (next, "Coro::transfer");
        SV_CORO (prev, "Coro::transfer");
        transfer (aTHX_ SvSTATE (prev), SvSTATE (next), flags);
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
        SvREFCNT_dec (coro->args);
        Safefree (coro);

void
_exit(code)
	int	code
        PROTOTYPE: $
	CODE:
	_exit (code);

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
          returnstk = SvRV ((SV *)get_sv ("Coro::Cont::return", FALSE));

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
          coroapi.cede     = api_cede;
          coroapi.ready    = api_ready;
          coroapi.nready   = &coro_nready;
          coroapi.current  = coro_current;

          GCoroAPI = &coroapi;
          sv_setiv(sv, (IV)&coroapi);
          SvREADONLY_on(sv);
        }
}

#if !PERL_MICRO

void
ready(self)
	SV *	self
        PROTOTYPE: $
	CODE:
        api_ready (self);

#endif

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
	CODE:
        api_schedule ();

void
cede(...)
	PROTOTYPE:
	CODE:
        api_cede ();

