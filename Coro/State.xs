#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#if 0
# define CHK(x) (void *)0
#else
# define CHK(x) if (!(x)) croak("FATAL, CHK: " #x)
#endif

struct coro {
  U8 dowarn;
  AV *defav;
  
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

  AV *args;
};

typedef struct coro *Coro__State;
typedef struct coro *Coro__State_or_hashref;

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

#if 0 /* NONOTUNDERSTOOD */
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

/* the next tow functions merely cache the padlists */
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

static void
save_state(pTHX_ Coro__State c)
{
  {
    dSP;
    I32 cxix = cxstack_ix;
    PERL_SI *top_si = PL_curstackinfo;
    PERL_CONTEXT *ccstk = cxstack;

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
                    XPUSHs ((SV *)CvOWNER(cv));
#endif
                    EXTEND (SP, 3);
                    PUSHs ((SV *)CvDEPTH(cv));
                    PUSHs ((SV *)CvPADLIST(cv));
                    PUSHs ((SV *)cv);

                    get_padlist (cv);

                    CvDEPTH(cv) = 0;
#ifdef USE_THREADS
                    CvOWNER(cv) = 0;
                    error must unlock this cv etc.. etc...
                    if you are here wondering about this error message then
                    the reason is that it will not work as advertised yet
#endif
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

  c->dowarn = PL_dowarn;
  c->defav = GvAV (PL_defgv);
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

#define LOAD(state) do { load_state(aTHX_ state); SPAGAIN; } while (0)
#define SAVE(state) do { PUTBACK; save_state(aTHX_ state); } while (0)

static void
load_state(pTHX_ Coro__State c)
{
  PL_dowarn = c->dowarn;
  GvAV (PL_defgv) = c->defav;
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

  {
    dSP;
    CV *cv;

    /* now do the ugly restore mess */
    while ((cv = (CV *)POPs))
      {
        AV *padlist = (AV *)POPs;

        put_padlist (cv);
        CvPADLIST(cv) = padlist;
        CvDEPTH(cv) = (I32)POPs;

#ifdef USE_THREADS
        CvOWNER(cv) = (struct perl_thread *)POPs;
        error does not work either
#endif
      }

    PUTBACK;
  }
}

/* this is an EXACT copy of S_nuke_stacks in perl.c, which is unfortunately static */
STATIC void
destroy_stacks(pTHX)
{
  /* die does this while calling POPSTACK, but I just don't see why. */
  /* OTOH, die does not have a memleak, but we do... */
  dounwind(-1);

  /* is this ugly, I ask? */
  while (PL_scopestack_ix)
    LEAVE;

  while (PL_curstackinfo->si_next)
    PL_curstackinfo = PL_curstackinfo->si_next;

  while (PL_curstackinfo)
    {
      PERL_SI *p = PL_curstackinfo->si_prev;

      SvREFCNT_dec(PL_curstackinfo->si_stack);
      Safefree(PL_curstackinfo->si_cxstack);
      Safefree(PL_curstackinfo);
      PL_curstackinfo = p;
  }

	if (PL_scopestack_ix != 0)
	    Perl_warner(aTHX_ WARN_INTERNAL,
	         "Unbalanced scopes: %ld more ENTERs than LEAVEs\n",
		 (long)PL_scopestack_ix);
	if (PL_savestack_ix != 0)
	    Perl_warner(aTHX_ WARN_INTERNAL,
		 "Unbalanced saves: %ld more saves than restores\n",
		 (long)PL_savestack_ix);
	if (PL_tmps_floor != -1)
	    Perl_warner(aTHX_ WARN_INTERNAL,"Unbalanced tmps: %ld more allocs than frees\n",
		 (long)PL_tmps_floor + 1);
  /*
                 */
  Safefree(PL_tmps_stack);
  Safefree(PL_markstack);
  Safefree(PL_scopestack);
  Safefree(PL_savestack);
  Safefree(PL_retstack);
}

#define SUB_INIT "Coro::State::_newcoro"

MODULE = Coro::State                PACKAGE = Coro::State

PROTOTYPES: ENABLE

BOOT:
	if (!padlist_cache)
	  padlist_cache = newHV ();

Coro::State
_newprocess(args)
        SV *	args
        PROTOTYPE: $
        CODE:
        Coro__State coro;

        if (!SvROK (args) || SvTYPE (SvRV (args)) != SVt_PVAV)
          croak ("Coro::State::newprocess expects an arrayref");
        
        New (0, coro, 1, struct coro);

        coro->mainstack = 0; /* actual work is done inside transfer */
        coro->args = (AV *)SvREFCNT_inc (SvRV (args));

        RETVAL = coro;
        OUTPUT:
        RETVAL

void
transfer(prev,next)
        Coro::State_or_hashref	prev
        Coro::State_or_hashref	next
        CODE:

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
                SAVE (prev);
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
                SAVE (prev);

                /*
                 * emulate part of the perl startup here.
                 */
                UNOP myop;

                init_stacks (); /* from perl.c */
                PL_op = (OP *)&myop;
                /*PL_curcop = 0;*/
                GvAV (PL_defgv) = (AV *)SvREFCNT_inc ((SV *)next->args);

                SPAGAIN;
                Zero(&myop, 1, UNOP);
                myop.op_next = Nullop;
                myop.op_flags = OPf_WANT_VOID;

                PUSHMARK(SP);
                XPUSHs ((SV*)get_cv(SUB_INIT, TRUE));
                PUTBACK;
                /*
                 * the next line is slightly wrong, as PL_op->op_next
                 * is actually being executed so we skip the first op.
                 * that doesn't matter, though, since it is only
                 * pp_nextstate and we never return...
                 */
                PL_op = Perl_pp_entersub(aTHX);
                SPAGAIN;

                ENTER;
              }
          }

void
DESTROY(coro)
        Coro::State	coro
        CODE:

        if (coro->mainstack)
          {
            struct coro temp;

            SAVE(aTHX_ (&temp));
            LOAD(aTHX_ coro);

            destroy_stacks ();
            SvREFCNT_dec ((SV *)GvAV (PL_defgv));

            LOAD((&temp));
          }

        SvREFCNT_dec (coro->args);
        Safefree (coro);


