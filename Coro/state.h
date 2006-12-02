/* list the interpreter variables that need to be saved/restored */
/* mostly copied from thrdvar.h */

VAR(stack_sp,      SV **)          /* top of the stack */
VAR(op,            OP *)           /* currently executing op */
VAR(curpad,        SV **)          /* active pad (lexicals+tmps) */

VAR(stack_base,    SV **)
VAR(stack_max,     SV **)

VAR(scopestack,    I32 *)          /* scopes we've ENTERed */
VAR(scopestack_ix, I32)
VAR(scopestack_max,I32)

VAR(savestack,     ANY *)          /* items that need to be restored
                                      when LEAVEing scopes we've ENTERed */
VAR(savestack_ix,  I32)
VAR(savestack_max, I32)

VAR(tmps_stack,    SV **)          /* mortals we've made */
VAR(tmps_ix,       I32)
VAR(tmps_floor,    I32)
VAR(tmps_max,      I32)

VAR(markstack,     I32 *)          /* stack_sp locations we're remembering */
VAR(markstack_ptr, I32 *)
VAR(markstack_max, I32 *)

#if !PERL_VERSION_ATLEAST (5,9,0)
VAR(retstack,      OP **)          /* OPs we have postponed executing */
VAR(retstack_ix,   I32)
VAR(retstack_max,  I32)
#endif

VAR(curpm,         PMOP *)         /* what to do \ interps in REs from */
VAR(curcop,        COP *)

VAR(in_eval,       int)            /* trap "fatal" errors? */
VAR(localizing,    int)            /* are we processing a local() list? */

VAR(curstack,      AV *)           /* THE STACK */
VAR(curstackinfo,  PERL_SI *)      /* current stack + context */
VAR(mainstack,     AV *)           /* the stack when nothing funny is happening */
VAR(sortcop,       OP *)           /* user defined sort routine */
VAR(sortstash,     HV *)           /* which is in some package or other */
VAR(sortcxix,      I32)            /* from pp_ctl.c */

VAR(comppad,       AV *)           /* storage for lexically scoped temporaries */

