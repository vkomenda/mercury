%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module follow_code.
% Main author: conway.

%-----------------------------------------------------------------------------%

:- interface.
:- import_module hlds, llds.

:- pred move_follow_code(module_info, module_info).
:- mode move_follow_code(in, out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.
:- import_module list, map, set, std_util.
:- import_module mode_util, term, require.
:- import_module quantification.

%-----------------------------------------------------------------------------%

	% Traverse the module structure, calling `move_follow_code_in_goal'
	% for each procedure body.

move_follow_code(ModuleInfo0, ModuleInfo1) :-
	module_info_predids(ModuleInfo0, PredIds),
	move_follow_code_in_preds(PredIds, ModuleInfo0, ModuleInfo1).

:- pred move_follow_code_in_preds(list(pred_id), module_info, module_info).
:- mode move_follow_code_in_preds(in, in, out) is det.

move_follow_code_in_preds([], ModuleInfo, ModuleInfo).
move_follow_code_in_preds([PredId | PredIds], ModuleInfo0, ModuleInfo) :-
	module_info_preds(ModuleInfo0, PredTable),
	map__lookup(PredTable, PredId, PredInfo),
	( pred_info_is_imported(PredInfo) ->
		ModuleInfo1 = ModuleInfo0
	;
		pred_info_procids(PredInfo, ProcIds),
		move_follow_code_in_procs(ProcIds, PredId, ModuleInfo0,
			ModuleInfo1)
	),
	move_follow_code_in_preds(PredIds, ModuleInfo1, ModuleInfo).

:- pred move_follow_code_in_procs(list(proc_id), pred_id, module_info,
					module_info).
:- mode move_follow_code_in_procs(in, in, in, out) is det.

move_follow_code_in_procs([], _PredId, ModuleInfo, ModuleInfo).
move_follow_code_in_procs([ProcId | ProcIds], PredId, ModuleInfo0,
					ModuleInfo) :-
	module_info_preds(ModuleInfo0, PredTable0),
	map__lookup(PredTable0, PredId, PredInfo0),
	pred_info_procedures(PredInfo0, ProcTable0),
	map__lookup(ProcTable0, ProcId, ProcInfo0),

	proc_info_goal(ProcInfo0, Goal0),
	proc_info_headvars(ProcInfo0, HeadVars),

	move_follow_code_in_goal(Goal0, ModuleInfo0, Goal1),
	implicitly_quantify_clause_body(HeadVars, Goal1, Goal),

	proc_info_set_goal(ProcInfo0, Goal, ProcInfo),
	map__set(ProcTable0, ProcId, ProcInfo, ProcTable),
	pred_info_set_procedures(PredInfo0, ProcTable, PredInfo),
	map__set(PredTable0, PredId, PredInfo, PredTable),
	module_info_set_preds(ModuleInfo0, PredTable, ModuleInfo1),
	move_follow_code_in_procs(ProcIds, PredId, ModuleInfo1, ModuleInfo).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- pred move_follow_code_in_goal(hlds__goal, module_info, hlds__goal).
:- mode move_follow_code_in_goal(in, in, out) is det.

move_follow_code_in_goal(Goal0 - GoalInfo, ModuleInfo, Goal - GoalInfo) :-
	move_follow_code_in_goal_2(Goal0, ModuleInfo, Goal).

%-----------------------------------------------------------------------------%

:- pred move_follow_code_in_goal_2(hlds__goal_expr, module_info, hlds__goal_expr).
:- mode move_follow_code_in_goal_2(in, in, out) is det.

move_follow_code_in_goal_2(conj(Goals0), ModuleInfo, conj(Goals)) :-
	move_follow_code_in_conj(Goals0, ModuleInfo, Goals).

move_follow_code_in_goal_2(disj(Goals0), ModuleInfo, disj(Goals)) :-
	move_follow_code_in_disj(Goals0, ModuleInfo, Goals).

move_follow_code_in_goal_2(not(Vars, Goal0), ModuleInfo, not(Vars, Goal)) :-
	move_follow_code_in_goal(Goal0, ModuleInfo, Goal).

move_follow_code_in_goal_2(switch(Var, Cases0), 
					ModuleInfo, switch(Var, Cases)) :-
	move_follow_code_in_cases(Cases0, ModuleInfo, Cases).

move_follow_code_in_goal_2(if_then_else(Vars, Cond0, Then0, Else0), 
			ModuleInfo, if_then_else(Vars, Cond, Then, Else)) :-
	move_follow_code_in_goal(Cond0, ModuleInfo, Cond),
	move_follow_code_in_goal(Then0, ModuleInfo, Then),
	move_follow_code_in_goal(Else0, ModuleInfo, Else).

move_follow_code_in_goal_2(some(Vars, Goal0), ModuleInfo, some(Vars, Goal)) :-
	move_follow_code_in_goal(Goal0, ModuleInfo, Goal).

move_follow_code_in_goal_2(call(A,B,C,D,E,F), _, call(A,B,C,D,E,F)).

move_follow_code_in_goal_2(unify(A,B,C,D,E), _, unify(A,B,C,D,E)).

%-----------------------------------------------------------------------------%

:- pred move_follow_code_in_disj(list(hlds__goal),
						module_info, list(hlds__goal)).
:- mode move_follow_code_in_disj(in, in, out) is det.

move_follow_code_in_disj([], _ModuleInfo, []).
move_follow_code_in_disj([Goal0|Goals0], ModuleInfo, [Goal|Goals]) :-
	move_follow_code_in_goal(Goal0, ModuleInfo, Goal),
	move_follow_code_in_disj(Goals0, ModuleInfo, Goals).

%-----------------------------------------------------------------------------%

:- pred move_follow_code_in_cases(list(case), module_info, list(case)).
:- mode move_follow_code_in_cases(in, in, out) is det.

move_follow_code_in_cases([], _ModuleInfo, []).
move_follow_code_in_cases([case(Cons, Goal0)|Goals0], ModuleInfo,
						[case(Cons, Goal)|Goals]) :-
	move_follow_code_in_goal(Goal0, ModuleInfo, Goal),
	move_follow_code_in_cases(Goals0, ModuleInfo, Goals).

%-----------------------------------------------------------------------------%

:- pred move_follow_code_in_conj(list(hlds__goal), module_info,
							list(hlds__goal)).
:- mode move_follow_code_in_conj(in, in, out) is det.

	% find the first branched structure, and split the
	% conj into those goals before and after it.

move_follow_code_in_conj([], _ModuleInfo, []).
move_follow_code_in_conj([Goal0 | Goals0], ModuleInfo, [Goal | Goals]) :-
	move_follow_code_in_goal(Goal0, ModuleInfo, Goal1),
	(
		move_follow_code_is_branched(Goal1)
	->
		move_follow_code_select(Goals0, FollowGoals, RestGoals0),
		move_follow_code_move_goals(Goal1, FollowGoals, Goal),
		move_follow_code_in_conj(RestGoals0, ModuleInfo, Goals)
	;
		Goal = Goal1,
		move_follow_code_in_conj(Goals0, ModuleInfo, Goals)
	).

%-----------------------------------------------------------------------------%

:- pred move_follow_code_select(list(hlds__goal),
					list(hlds__goal), list(hlds__goal)).
:- mode move_follow_code_select(in, out, out) is det.

move_follow_code_select([], [], []).
move_follow_code_select([Goal|Goals], FollowGoals, RestGoals) :-
	(
		move_follow_code_is_builtin(Goal)
	->
		move_follow_code_select(Goals, FollowGoals0, RestGoals),
		FollowGoals = [Goal|FollowGoals0]
	;
		FollowGoals = [],
		RestGoals = [Goal|Goals]
	).


%-----------------------------------------------------------------------------%

:- pred move_follow_code_move_goals(hlds__goal, list(hlds__goal), hlds__goal).
:- mode move_follow_code_move_goals(in, in, out) is det.

move_follow_code_move_goals(Goal0 - GoalInfo, FollowGoals, Goal - GoalInfo) :-
	( move_follow_code_move_goals_2(Goal0, FollowGoals, Goal1) ->
		Goal = Goal1
	;
		error("bizarre goal")
	).

:- pred move_follow_code_move_goals_2(hlds__goal_expr,
					list(hlds__goal), hlds__goal_expr).
:- mode move_follow_code_move_goals_2(in, in, out) is semidet.

move_follow_code_move_goals_2(switch(Var, Cases0), FollowGoals,
						switch(Var, Cases)) :-
	move_follow_code_move_goals_cases(Cases0, FollowGoals, Cases).
move_follow_code_move_goals_2(disj(Goals0), FollowGoals, disj(Goals)) :-
	move_follow_code_move_goals_disj(Goals0, FollowGoals, Goals).
move_follow_code_move_goals_2(if_then_else(Vars, Cond, Then0, Else0),
			FollowGoals, if_then_else(Vars, Cond, Then, Else)) :-
	conjoin_goal_and_goal_list(Then0, FollowGoals, Then),
	conjoin_goal_and_goal_list(Else0, FollowGoals, Else).

%-----------------------------------------------------------------------------%

:- pred move_follow_code_move_goals_cases(list(case),
						list(hlds__goal), list(case)).
:- mode move_follow_code_move_goals_cases(in, in, out) is det.

move_follow_code_move_goals_cases([], _FollowGoals, []).
move_follow_code_move_goals_cases([Case0|Cases0], FollowGoals, [Case|Cases]) :-
	Case0 = case(Cons, Goal0),
	conjoin_goal_and_goal_list(Goal0, FollowGoals, Goal),
	Case = case(Cons, Goal),
	move_follow_code_move_goals_cases(Cases0, FollowGoals, Cases).

%-----------------------------------------------------------------------------%

:- pred move_follow_code_move_goals_disj(list(hlds__goal),
					list(hlds__goal), list(hlds__goal)).
:- mode move_follow_code_move_goals_disj(in, in, out) is det.

move_follow_code_move_goals_disj([], _FollowGoals, []).
move_follow_code_move_goals_disj([Goal0|Goals0], FollowGoals, [Goal|Goals]) :-
	conjoin_goal_and_goal_list(Goal0, FollowGoals, Goal),
	move_follow_code_move_goals_disj(Goals0, FollowGoals, Goals).

%-----------------------------------------------------------------------------%

	% Takes a goal and a list of goals, and conjoins them (with a
	% potentially blank goal_info).

:- pred conjoin_goal_and_goal_list(hlds__goal, list(hlds__goal), hlds__goal).
:- mode conjoin_goal_and_goal_list(in, in, out) is det.

conjoin_goal_and_goal_list(Goal0, FollowGoals, Goal) :-
	goal_info_init(GoalInfo),
	goal_to_conj_list(Goal0, GoalList0),
	list__append(GoalList0, FollowGoals, GoalList),
	conj_list_to_goal(GoalList, GoalInfo, Goal).

%-----------------------------------------------------------------------------%

:- pred move_follow_code_is_branched(hlds__goal).
:- mode move_follow_code_is_branched(in) is semidet.

move_follow_code_is_branched(Goal - _GoalInfo) :-
	(
		Goal = switch(_,_)
	->
		true
	;
		Goal = if_then_else(_,_,_,_)
	->
		true
	;
		Goal = disj(_)
	).

%-----------------------------------------------------------------------------%

:- pred move_follow_code_is_builtin(hlds__goal).
:- mode move_follow_code_is_builtin(in) is semidet.

move_follow_code_is_builtin(Goal - _GoalInfo) :-
	(
		Goal = unify(_,_,_,_,_)
	->
		true
	;
		Goal = call(_,_,_,is_builtin, _, _)
	).
		
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
