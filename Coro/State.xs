#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#if 1
# define CHK(x) (void *)0
#else
# define CHK(x) if (!(x)) croak("FATAL, CHK: " #x)
#endif

#define MAY_FLUSH /* increases codesize */

#define SUB_INIT "Coro::State::initialize"

#define TRANSFER_SAVE_DEFAV	0x00000001
#define TRANSFER_SAVE_DEFSV	0x00000002
#define TRANSFER_SAVE_ERRSV	0x00000004

#define TRANSFER_SAVE_ALL	-1

struct coro {
  /* optionally saved, might be zero */
  AV *defav;
  SV *defsv;
  SV *errsv;
  
  /* saved global state not related to stacks */
  U8 dowarn;

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

  /* data associated with this coroutine (initial args) */
  AV *args;
};

typedef struct coro *Coro__State;
typedef struct coro *Coro__State_or_hashref;

static AV *main_mainstack; /* used to differentiate between $main and others */

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
STATIC AV *
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

#define LOAD(state)       SB load_state(aTHX_ state); SPAGAIN;       SE
#define SAVE(state,flags) SB PUTBACK; save_state(aTHX_ state,flags); SE

#define REPLACE_SV(sv,val) SB SvREFCNT_dec(sv); (sv) = (val); SE

static void
load_state(pTHX_ Coro__State c)
{
  PL_dowarn = c->dowarn;

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
        do
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
        while (cxix >= 0);

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

  /* I have not the slightest idea of why av_reify is necessary */
  /* but if it's missing the defav contents magically get replaced sometimes */
  if (c->defav)
    av_reify (c->defav);

  c->dowarn = PL_dowarn;

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
}

/*
 * destroy the stacks, the callchain etc...
 * still there is a memleak of 128 bytes...
 */
STATIC void
destroy_stacks(pTHX)
{
  /* is this ugly, I ask? */
  while (PL_scopestack_ix)
    LEAVE;

  /* sure it is, but more important: is it correct?? :/ */
  while (PL_tmps_ix > PL_tmps_floor) /* should only ever be one iteration */
    FREETMPS;

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

      dounwind(-1);

      SvREFCNT_dec(PL_curstackinfo->si_stack);
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

STATIC void
transfer(pTHX_ struct coro *prev, struct coro *next, int flags)
{
  dSP;

  if (prev != next)
    {
      /*
       * this could be done in newprocess which would lead to
       * extremely elegant and fast (just SAVE/LOAD)
       * code here, but lazy allocation of stacks has also
       * some virtues and the overhead of the if() is nil.
       */
      if (next->mainstack)
        {
          SAVE (prev, flags);
          LOAD (next);
          /* mark this state as in-use */
          next->mainstack = 0;
          next->tmps_ix = -2;
        }
      else if (next->tmps_ix == -2)
        {
          croak ("tried to transfer to running coroutine");
        }
      else
        {
          /*
           * emulate part of the perl startup here.
           */
          UNOP myop;

          SAVE (prev, -1); /* first get rid of the old state */

          init_stacks (); /* from perl.c */
          SPAGAIN;

          PL_op = (OP *)&myop;
          /*PL_curcop = 0;*/
          SvREFCNT_dec (GvAV (PL_defgv));
          GvAV (PL_defgv) = next->args;

          Zero(&myop, 1, UNOP);
          myop.op_next = Nullop;
          myop.op_flags = OPf_WANT_VOID;

          PUSHMARK(SP);
          XPUSHs ((SV*)get_cv(SUB_INIT, TRUE));
          /*
           * the next line is slightly wrong, as PL_op->op_next
           * is actually being executed so we skip the first op.
           * that doesn't matter, though, since it is only
           * pp_nextstate and we never return...
           * ah yes, and I don't care anyways ;)
           */
          PUTBACK;
          PL_op = pp_entersub(aTHX);
          SPAGAIN;

          ENTER; /* necessary e.g. for dounwind */
        }
    }
}

MODULE = Coro::State                PACKAGE = Coro::State

PROTOTYPES: ENABLE

BOOT:
{       /* {} necessary for stoopid perl-5.6.x */
	HV * stash = gv_stashpvn("Coro::State", 10, TRUE);

        newCONSTSUB (stash, "SAVE_DEFAV", newSViv (TRANSFER_SAVE_DEFAV));
        newCONSTSUB (stash, "SAVE_DEFSV", newSViv (TRANSFER_SAVE_DEFSV));
        newCONSTSUB (stash, "SAVE_ERRSV", newSViv (TRANSFER_SAVE_ERRSV));

	if (!padlist_cache)
	  padlist_cache = newHV ();

        main_mainstack = PL_mainstack;
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

        coro->mainstack = 0; /* actual work is done inside transfer */
        coro->args = (AV *)SvREFCNT_inc (SvRV (args));

        RETVAL = coro;
        OUTPUT:
        RETVAL

void
transfer(prev, next, flags = TRANSFER_SAVE_ALL)
        Coro::State_or_hashref	prev
        Coro::State_or_hashref	next
        int			flags
        PROTOTYPE: @
        CODE:

        transfer (aTHX_ prev, next, flags);

void
DESTROY(coro)
        Coro::State	coro
        CODE:

        if (coro->mainstack && coro->mainstack != main_mainstack)
          {
            struct coro temp;

            SAVE(aTHX_ (&temp), TRANSFER_SAVE_ALL);
            LOAD(aTHX_ coro);

            destroy_stacks ();

            LOAD((&temp)); /* this will get rid of defsv etc.. */
          }

        Safefree (coro);

        /*
         * there is one problematic case left (remember _recurse?)
         * consider the case when we
         *
         * 1. start a coroutine
         * 2. inside it descend into some xs functions
         * 3. xs function calls a callback
         * 4. callback switches to $main
         * 5. $main ends - we will end inside the xs function
         * 6. xs function returns and perl executes - what?
         *
         * to avoid this case we recurse in this function
         * and simply call my_exit(0), skipping other xs functions
         */

#if 0
void
_recurse()
	CODE:
        LEAVE;
        PL_stack_sp = PL_stack_base + ax - 1;
        PL_op = PL_op->op_next;
        CALLRUNOPS(aTHX);
        printf ("my_exit\n");
        my_exit (0);

#endif

void
flush()
	CODE:
#ifdef MAY_FLUSH
        flush_padlist_cache ();
#endif

MODULE = Coro::State                PACKAGE = Coro::Cont

# this is dirty (do you hear me?) and should be in it's own .xs

void
result(...)
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
        transfer(prev, next, 0);

