%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2002-2008 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
% 
% File: reassign.m.
% Author: zs.
% 
% This module implements an LLDS->LLDS transformation that optimizes away
% assignments to locations that already hold the assigned value.  It operates
% entirely within extended basic blocks.
%
% It is intended for instruction sequences such as the following extract
% from tree234.search:
%
%   MR_r1 = MR_stackvar(3);
%   MR_r2 = MR_stackvar(4);
%   MR_r3 = MR_const_field(MR_mktag(1), MR_stackvar(1), (MR_Integer) 2);
%   MR_r4 = MR_stackvar(2);
%   MR_succip = (MR_Code *) MR_stackvar(5);
%   if ((MR_tag(MR_r3) != MR_mktag((MR_Integer) 1))) {
%       MR_GOTO_LABEL(mercury.x3.search_3_0_i1);
%   }
%   MR_stackvar(1) = MR_r3;
%   MR_stackvar(2) = MR_r4;
%   MR_stackvar(3) = MR_r1;
%   MR_stackvar(4) = MR_r2;
%   MR_r2 = MR_r4;
%   MR_r3 = MR_const_field(MR_mktag(1), MR_r3, (MR_Integer) 0);
%   MR_call_localret(...)
%
% The code before the if statement is part of the procedure epilogue; the code
% after it is the code from the initial part of the procedure that fulljump
% optimization replaces the self-tail-call with.
%
% The objective of this module is to remove assignments such as the assignments
% to stackvars 2, 3 and 4 above, in which the register assigned to the stackvar
% comes from the same stackvar in the first place.
%
% In general, for every assignment TargetLval = SourceRval, we record that
% TargetLval now contains SourceRval; if SourceRval is of the form
% lval(SourceLval), we also record that SourceLval now contains
% lval(TargetLval). Later on, if we find an assignment that assigns to an lval
% a value that it already holds, we remove the assignment.  The removed
% assignment will either be a copy of the original assignment TargetLval =
% SourceRval, or its converse, SourceLval = lval(TargetLval).  The mechanism
% that enables us to do this is a map that maps lvals (e.g. TargetLval)
% to its known contents (e.g. SourceRval).
%
% Of course, if any of the lvals occurring on the right hand side of an
% assignment change, we cannot remove a later copy of that assignment or of
% its converse. For example, we cannot remove the final assignment in the
% following code:
%
%   MR_r3 = MR_stackvar(1);
%   ...
%   MR_stackvar(1) = MR_r2;
%   ...
%   MR_r3 = MR_stackvar(1);
%
% We handle this by keeping track of which lvals an entry in the known contents
% map depends on. If one of these lvals is updated, we invalidate the dependent
% entries in the known contents map (i.e. we delete them).
%
% The lvals on which TargetLval depends include any lvals occurring inside it.
% We cannot optimize away the second assignment to the field below because
% even though the two field references are the same syntactically, they refer
% to different memory locations due to the update of MR_r5 between them.
%
%   MR_field(MR_mktag(1), MR_r5, 1) = r2;
%   ...
%   MR_incr_hp(MR_r5, 4);
%   ...
%   MR_field(MR_mktag(1), MR_r5, 1) = r2;
%
%
% The lvals on which TargetLval depends need not include TargetLval itself,
% since an assignment to TargetLval will in any case override the previous
% entry for TargetLval in the known contents map. This takes care of code
% sequences such as:
%
%   MR_r3 = MR_stackvar(1);
%   ...
%   MR_r3 = MR_r2;
%   ...
%   MR_r3 = MR_stackvar(1);
%
% The optimization makes conservative assumptions in several places, meaning
% it clobbers entries in the known contents map whenever an instruction *could*
% affect the entry, even if it in fact doesn't. For example, we clobber the
% known contents map at calls, labels and ticket resets.
% 
%-----------------------------------------------------------------------------%

:- module ll_backend.reassign.
:- interface.

:- import_module ll_backend.llds.

:- import_module list.

%-----------------------------------------------------------------------------%

:- pred remove_reassign(list(instruction)::in, list(instruction)::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module libs.compiler_util.
:- import_module ll_backend.code_util.

:- import_module int.
:- import_module map.
:- import_module pair.
:- import_module set.
:- import_module svmap.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- type known_contents  ==  map(lval, rval).
:- type dependent_lval_map  ==  map(lval, set(lval)).

remove_reassign(Instrs0, Instrs) :-
    remove_reassign_loop(Instrs0, map.init, map.init, [], RevInstrs),
    list.reverse(RevInstrs, Instrs).

:- pred remove_reassign_loop(list(instruction)::in, known_contents::in,
    dependent_lval_map::in, list(instruction)::in, list(instruction)::out)
    is det.

remove_reassign_loop([], _, _, !RevInstrs).
remove_reassign_loop([Instr0 | Instrs0], !.KnownContentsMap, !.DepLvalMap,
        !RevInstrs) :-
    Instr0 = llds_instr(Uinstr0, _),
    (
        Uinstr0 = comment(_),
        !:RevInstrs = [Instr0 | !.RevInstrs]
    ;
        Uinstr0 = livevals(_),
        !:RevInstrs = [Instr0 | !.RevInstrs]
    ;
        Uinstr0 = block(_, _, _),
        unexpected(this_file, "remove_reassign_loop: block")
    ;
        Uinstr0 = assign(Target, Source),
        (
            map.search(!.KnownContentsMap, Target, KnownContents),
            KnownContents = Source
        ->
            % By not including Instr0 in !:RevInstrs, we are deleting Instr0.
            true
        ;
            !:RevInstrs = [Instr0 | !.RevInstrs],
            clobber_dependents(Target, !KnownContentsMap, !DepLvalMap),
            (
                % For Targets of the following form, the code generator ensures
                % that the storage location referred to by Target can only be
                % updated through the Target lval, and not through some other
                % lval, unless one uses mem_addr to explicitly create an alias
                % and mem_ref to access the memory location via that alias.
                no_implicit_alias_target(Target)
            ->
                record_known(Target, Source, !KnownContentsMap, !DepLvalMap)
            ;
                true
            )
        )
    ;
        Uinstr0 = keep_assign(_, _),
        !:RevInstrs = [Instr0 | !.RevInstrs]
    ;
        Uinstr0 = llcall(_, _, _, _, _, _),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % The call may clobber any lval.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = mkframe(_, _),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = label(_),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % We don't know what is stored where at the instructions that
        % jump here.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = goto(_),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % The value of !:KnownContentsMap doesn't really matter since the next
        % instruction (which must be a label) will reset it to empty anyway.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = computed_goto(_, _),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % The value of !:KnownContentsMap doesn't really matter since the next
        % instruction (which must be a label) will reset it to empty anyway.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = arbitrary_c_code(_, _, _),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % The C code may clobber any lval.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = if_val(_, _),
        !:RevInstrs = [Instr0 | !.RevInstrs]
    ;
        Uinstr0 = save_maxfr(Target),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        clobber_dependents(Target, !KnownContentsMap, !DepLvalMap),
        svmap.delete(Target, !KnownContentsMap)
    ;
        Uinstr0 = restore_maxfr(_),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        clobber_dependents(hp, !KnownContentsMap, !DepLvalMap)
    ;
        Uinstr0 = incr_hp(Target, _, _, _, _, _, _, _),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        clobber_dependents(Target, !KnownContentsMap, !DepLvalMap),
        clobber_dependents(hp, !KnownContentsMap, !DepLvalMap)
    ;
        Uinstr0 = mark_hp(Target),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        clobber_dependents(Target, !KnownContentsMap, !DepLvalMap),
        svmap.delete(Target, !KnownContentsMap)
    ;
        Uinstr0 = restore_hp(_),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        clobber_dependents(hp, !KnownContentsMap, !DepLvalMap)
    ;
        Uinstr0 = free_heap(_),
        !:RevInstrs = [Instr0 | !.RevInstrs]
        % There is no need to update KnownContentsMap since later code
        % should never refer to the freed cell.
    ;
        ( Uinstr0 = push_region_frame(_, EmbeddedFrame)
        ; Uinstr0 = region_set_fixed_slot(_, EmbeddedFrame, _)
        ; Uinstr0 = use_and_maybe_pop_region_frame(_, EmbeddedFrame)
        ),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        update_embdedded_frame(EmbeddedFrame, !KnownContentsMap, !DepLvalMap)
    ;
        Uinstr0 = region_fill_frame(_, EmbeddedFrame, _, NumLval, AddrLval),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        update_embdedded_frame(EmbeddedFrame, !KnownContentsMap, !DepLvalMap),
        clobber_dependents(NumLval, !KnownContentsMap, !DepLvalMap),
        clobber_dependents(AddrLval, !KnownContentsMap, !DepLvalMap),
        svmap.delete(NumLval, !KnownContentsMap),
        svmap.delete(AddrLval, !KnownContentsMap)
    ;
        Uinstr0 = store_ticket(Target),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        clobber_dependents(Target, !KnownContentsMap, !DepLvalMap)
    ;
        Uinstr0 = reset_ticket(_, _),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % The reset operation may modify any lval.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = prune_ticket,
        !:RevInstrs = [Instr0 | !.RevInstrs]
    ;
        Uinstr0 = discard_ticket,
        !:RevInstrs = [Instr0 | !.RevInstrs]
    ;
        Uinstr0 = mark_ticket_stack(Target),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        clobber_dependents(Target, !KnownContentsMap, !DepLvalMap)
    ;
        Uinstr0 = prune_tickets_to(_),
        !:RevInstrs = [Instr0 | !.RevInstrs]
%   ;
%       Uinstr0 = discard_tickets_to(_),
%       !:RevInstrs = [Instr0 | !.RevInstrs]
    ;
        Uinstr0 = incr_sp(_, _, _),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % All stackvars now refer to new locations. Rather than delete
        % only stackvars from KnownContentsMap, we delete everything.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = decr_sp(_),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % All stackvars now refer to new locations. Rather than delete
        % only stackvars from KnownContentsMap, we delete everything.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = decr_sp_and_return(_),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % All stackvars now refer to new locations. Rather than delete
        % only stackvars from KnownContentsMap, we delete everything.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = foreign_proc_code(_, _, _, _, _, _, _, _, _),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % The C code may clobber any lval.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = init_sync_term(Target, _),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        clobber_dependents(Target, !KnownContentsMap, !DepLvalMap)
    ;
        Uinstr0 = fork_new_child(_, _),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % Both the parent and the child thread jump to labels specified
        % by the fork instruction, so the value of !:KnownContentsMap doesn't
        % really matter since the next instruction (which must be a label)
        % will reset it to empty anyway.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        Uinstr0 = join_and_continue(_, _),
        !:RevInstrs = [Instr0 | !.RevInstrs],
        % Other threads may modify any lval.
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ),
    remove_reassign_loop(Instrs0, !.KnownContentsMap, !.DepLvalMap,
        !RevInstrs).

:- pred update_embdedded_frame(embedded_stack_frame_id::in,
    known_contents::in, known_contents::out,
    dependent_lval_map::in, dependent_lval_map::out) is det.

update_embdedded_frame(EmbeddedFrame, !KnownContentsMap, !DepLvalMap) :-
    EmbeddedFrame = embedded_stack_frame_id(StackId, FirstSlot, LastSlot),
    update_embdedded_frame_2(StackId, FirstSlot, LastSlot,
        !KnownContentsMap, !DepLvalMap).

:- pred update_embdedded_frame_2(main_stack::in, int::in, int::in,
    known_contents::in, known_contents::out,
    dependent_lval_map::in, dependent_lval_map::out) is det.

update_embdedded_frame_2(StackId, CurSlot, LastSlot,
        !KnownContentsMap, !DepLvalMap) :-
    ( CurSlot =< LastSlot ->
        StackVar = stack_slot_num_to_lval(StackId, CurSlot),
        clobber_dependents(StackVar, !KnownContentsMap, !DepLvalMap),
        svmap.delete(StackVar, !KnownContentsMap),
        update_embdedded_frame_2(StackId, CurSlot + 1, LastSlot,
            !KnownContentsMap, !DepLvalMap)
    ;
        true
    ).

    % Succeed iff the lval cannot have an alias created for it without the
    % use of a mem_ref lval or an instruction with embedded C code, both of
    % which cause us to clobber the known contents map.
    %
:- pred no_implicit_alias_target(lval::in) is semidet.

no_implicit_alias_target(temp(_, _)).
no_implicit_alias_target(reg(_, _)).
no_implicit_alias_target(stackvar(_)).
no_implicit_alias_target(framevar(_)).

:- pred clobber_dependents(lval::in, known_contents::in, known_contents::out,
    dependent_lval_map::in, dependent_lval_map::out) is det.

clobber_dependents(Target, !KnownContentsMap, !DepLvalMap) :-
    ( map.search(!.DepLvalMap, Target, DepLvals) ->
        set.fold(clobber_dependent, DepLvals, !KnownContentsMap),
        map.delete(!.DepLvalMap, Target, !:DepLvalMap)
    ;
        true
    ),
    % LLDS code can refer to arbitrary locations on the stack or in the heap
    % with mem_ref lvals. Since we don't keep track of which locations have
    % their addresses taken, on any assignment through a mem_ref lval we throw
    % way the known contents map. This is a conservative approximation of the
    % desired behaviour, which would invalidate only the entries of lvals
    % that may be referred to via this mem_ref.
    SubLvals = lvals_in_rval(lval(Target)),
    (
        some [SubLval] (
            list.member(SubLval, SubLvals),
            SubLval = mem_ref(_)
        )
    ->
        !:KnownContentsMap = map.init,
        !:DepLvalMap = map.init
    ;
        true
    ).

:- pred clobber_dependent(lval::in, known_contents::in, known_contents::out)
    is det.

clobber_dependent(Dependent, KnownContentsMap0, KnownContentsMap) :-
    map.delete(KnownContentsMap0, Dependent, KnownContentsMap).

:- pred record_known(lval::in, rval::in,
    known_contents::in, known_contents::out,
    dependent_lval_map::in, dependent_lval_map::out) is det.

record_known(TargetLval, SourceRval, !KnownContentsMap, !DepLvalMap) :-
    SourceSubLvals = lvals_in_rval(SourceRval),
    ( list.member(TargetLval, SourceSubLvals) ->
        % The act of assigning to TargetLval has modified the value of
        % SourceRval, so we can't eliminate any copy of this assignment
        % or its converse.
        true
    ;
        record_known_lval_rval(TargetLval, SourceRval,
            !KnownContentsMap, !DepLvalMap),
        ( SourceRval = lval(SourceLval) ->
            record_known_lval_rval(SourceLval, lval(TargetLval),
                !KnownContentsMap, !DepLvalMap)
        ;
            true
        )
    ).

:- pred record_known_lval_rval(lval::in, rval::in,
    known_contents::in, known_contents::out,
    dependent_lval_map::in, dependent_lval_map::out) is det.

record_known_lval_rval(TargetLval, SourceRval, !KnownContentsMap,
        !DepLvalMap) :-
    ( map.search(!.KnownContentsMap, TargetLval, OldRval) ->
        % TargetLval no longer depends on the lvals in OldRval;
        % it depends on the lvals in SourceRval instead. If any lvals
        % occur in both, we delete TargetLval from their entries here
        % and will add it back in a few lines later on.
        %
        % TargetLval still depends on the lvals inside it.
        OldSubLvals = lvals_in_rval(OldRval),
        list.foldl(make_not_dependent(TargetLval), OldSubLvals, !DepLvalMap)
    ;
        true
    ),
    TargetSubLvals = lvals_in_lval(TargetLval),
    SourceSubLvals = lvals_in_rval(SourceRval),
    list.append(TargetSubLvals, SourceSubLvals, AllSubLvals),
    list.foldl(make_dependent(TargetLval), AllSubLvals, !DepLvalMap),
    svmap.set(TargetLval, SourceRval, !KnownContentsMap).

:- pred make_not_dependent(lval::in, lval::in,
    dependent_lval_map::in, dependent_lval_map::out) is det.

make_not_dependent(Target, SubLval, !DepLvalMap) :-
    ( map.search(!.DepLvalMap, SubLval, DepLvals0) ->
        set.delete(DepLvals0, Target, DepLvals),
        svmap.det_update(SubLval, DepLvals, !DepLvalMap)
    ;
        true
    ).

:- pred make_dependent(lval::in, lval::in,
    dependent_lval_map::in, dependent_lval_map::out) is det.

make_dependent(Target, SubLval, !DepLvalMap) :-
    ( map.search(!.DepLvalMap, SubLval, DepLvals0) ->
        set.insert(DepLvals0, Target, DepLvals),
        svmap.det_update(SubLval, DepLvals, !DepLvalMap)
    ;
        DepLvals = set.make_singleton_set(Target),
        svmap.det_insert(SubLval, DepLvals, !DepLvalMap)
    ).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "reassign.m".

%-----------------------------------------------------------------------------%
:- end_module reassign.
%-----------------------------------------------------------------------------%
