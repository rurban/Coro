#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

typedef struct coro {
  U8 dowarn;
  
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

  SV *proc;
} *Coro__State;

#define SAVE(c)	\
  c->dowarn = PL_dowarn;		\
  c->curstackinfo = PL_curstackinfo;	\
  c->curstack = PL_curstack;		\
  c->mainstack = PL_mainstack;		\
  c->stack_sp = PL_stack_sp;		\
  c->op = PL_op;			\
  c->curpad = PL_curpad;		\
  c->stack_base = PL_stack_base;	\
  c->stack_max = PL_stack_max;		\
  c->tmps_stack = PL_tmps_stack;	\
  c->tmps_floor = PL_tmps_floor;	\
  c->tmps_ix = PL_tmps_ix;		\
  c->tmps_max = PL_tmps_max;		\
  c->markstack = PL_markstack;		\
  c->markstack_ptr = PL_markstack_ptr;	\
  c->markstack_max = PL_markstack_max;	\
  c->scopestack = PL_scopestack;	\
  c->scopestack_ix = PL_scopestack_ix;	\
  c->scopestack_max = PL_scopestack_max;\
  c->savestack = PL_savestack;		\
  c->savestack_ix = PL_savestack_ix;	\
  c->savestack_max = PL_savestack_max;	\
  c->retstack = PL_retstack;		\
  c->retstack_ix = PL_retstack_ix;	\
  c->retstack_max = PL_retstack_max;	\
  c->curcop = PL_curcop;

#define LOAD(c)	\
  PL_dowarn = c->dowarn;		\
  PL_curstackinfo = c->curstackinfo;	\
  PL_curstack = c->curstack;		\
  PL_mainstack = c->mainstack;		\
  PL_stack_sp = c->stack_sp;		\
  PL_op = c->op;			\
  PL_curpad = c->curpad;		\
  PL_stack_base = c->stack_base;	\
  PL_stack_max = c->stack_max;		\
  PL_tmps_stack = c->tmps_stack;	\
  PL_tmps_floor = c->tmps_floor;	\
  PL_tmps_ix = c->tmps_ix;		\
  PL_tmps_max = c->tmps_max;		\
  PL_markstack = c->markstack;		\
  PL_markstack_ptr = c->markstack_ptr;	\
  PL_markstack_max = c->markstack_max;	\
  PL_scopestack = c->scopestack;	\
  PL_scopestack_ix = c->scopestack_ix;	\
  PL_scopestack_max = c->scopestack_max;\
  PL_savestack = c->savestack;		\
  PL_savestack_ix = c->savestack_ix;	\
  PL_savestack_max = c->savestack_max;	\
  PL_retstack = c->retstack;		\
  PL_retstack_ix = c->retstack_ix;	\
  PL_retstack_max = c->retstack_max;	\
  PL_curcop = c->curcop;

/* this is an EXACT copy of S_nuke_stacks in perl.c, which is unfortunately static */
STATIC void
S_nuke_stacks(pTHX)
{
    while (PL_curstackinfo->si_next)
	PL_curstackinfo = PL_curstackinfo->si_next;
    while (PL_curstackinfo) {
	PERL_SI *p = PL_curstackinfo->si_prev;
	/* curstackinfo->si_stack got nuked by sv_free_arenas() */
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

MODULE = Coro::State		PACKAGE = Coro::State

PROTOTYPES: ENABLE

Coro::State
newprocess(proc)
	SV *	proc
        PROTOTYPE: &
        CODE:
        Coro__State coro;
        
        New (0, coro, 1, struct coro);

        coro->mainstack = 0; /* actual work is done inside transfer */
        coro->proc = SvREFCNT_inc (proc);

        RETVAL = coro;
        OUTPUT:
        RETVAL

void
transfer(prev,next)
	Coro::State	prev
	Coro::State	next
        CODE:

        PUTBACK;
        SAVE (prev);

        /*
         * this could be done in newprocess which would to
         * extremely elegant and fast (just PUTBACK/SAVE/LOAD/SPAGAIN)
         * code here, but lazy allocation of stacks has also
         * some virtues and the overhead of the if() is nil.
         */
        if (next->mainstack)
          {
            LOAD (next);
            next->mainstack = 0; /* unnecessary but much cleaner */
            SPAGAIN;
          }
        else
          {
            /*
             * emulate part of the perl startup here.
             */
            UNOP myop;

            init_stacks ();
            PL_op = (OP *)&myop;
            /*PL_curcop = 0;*/

            SPAGAIN;
            Zero(&myop, 1, UNOP);
            myop.op_next = Nullop;
            myop.op_flags = OPf_WANT_VOID;

            EXTEND (SP,1);
            PUSHs (next->proc);
            
            PUTBACK;
            /*
             * the next line is slightly wrong, as PL_op->op_next
             * is actually being executed so we skip the first op
             * that doens't matter, though, since it is only
             * pp_nextstate and we never return...
             */
            PL_op = Perl_pp_entersub(aTHX);
            SPAGAIN;

            ENTER;
          }

void
DESTROY(coro)
	Coro::State	coro
        CODE:

        if (coro->mainstack)
          {
            struct coro temp;

            PUTBACK;
            SAVE((&temp));
            LOAD(coro);

            S_nuke_stacks ();

            LOAD((&temp));
            SPAGAIN;
          }

        SvREFCNT_dec (coro->proc);
        Safefree (coro);


