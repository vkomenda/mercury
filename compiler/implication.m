%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
% File: implication.nl
% Main author: squirrel (Jane Anna Langley)
%
% This module performs the inlining of implications as a part of the 
% language.
%
% This is a parse-tree to parse-tree transformation, to be performed
% just before the parse-tree is converted to the hlds.
% Immediately after this transformation is performed, negation is
% pushed inwards by the transformations in the file negation.nl.
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module implication.
:- interface.

:- import_module string, int, set, bintree, list, map, require, std_util.
:- import_module term, term_io, prog_io, varset.
:- import_module prog_util, prog_out, hlds_out.
:- import_module globals, options.
:- import_module make_tags, quantification.
:- import_module unify_proc, type_util.
:- import_module io.

:- pred implication__transform_operators(item_list, item_list,
						io__state, io__state).
:- mode implication__transform_operators(in, out, di, uo) is det.

:- pred implication__expand_implication(goal, goal, goal).
:- mode implication__expand_implication(in, in, out) is det.

:- pred implication__expand_equivalence(goal, goal, goal).
:- mode implication__expand_equivalence(in, in, out) is det.

%-----------------------------------------------------------------------------%
% PUBLIC PREDICATE IMPLEMENTATIONS:
%-----------------------------------------------------------------------------%
:- implementation.

	% implication__transform_operators/4
	% This is the top level, publically visible predicate of this
	% module.
implication__transform_operators(Items_In, Items_Out) -->
	globals__io_lookup_bool_option(verbose, Verbose),
	maybe_write_string(Verbose, 
		"% Transforming implication and equivalence..."),
	maybe_flush_output(Verbose),
	{ implication__transform_over_list(Items_In, Items_Out) },
	maybe_write_string(Verbose, " done.\n"),
	globals__io_lookup_bool_option(statistics, Statistics),
	maybe_report_stats(Statistics).

% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - %

implication__expand_implication(Goal1, Goal2, TransformedGoal) :-
	implication__transform_goal(implies(Goal1, Goal2), TransformedGoal).

% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - %

implication__expand_equivalence(Goal1, Goal2, TransformedGoal) :-
	implication__transform_goal(equivalent(Goal1, Goal2), TransformedGoal).

%-----------------------------------------------------------------------------%
% LOCAL PREDICATE DECLARATIONS:
%-----------------------------------------------------------------------------%

% Note: the types ``item_list'' and ``item_and_context'' are defined in
% prog_io.nl	

:- pred implication__transform_over_list(item_list, item_list).
:- mode implication__transform_over_list(in, out) is det.

:- pred implication__transform_item_and_context(item_and_context, 
		item_and_context).
:- mode implication__transform_item_and_context(in, out) is det.

:- pred implication__transform_item(item, item).
:- mode implication__transform_item(in, out) is det.

:- pred implication__transform_goal(goal, goal).
:- mode implication__transform_goal(in, out) is det.

%-----------------------------------------------------------------------------%
% LOCAL PREDICATE IMPLEMENTATIONS:
%-----------------------------------------------------------------------------%

	% implication__transform_over_list/2
	
	% This predicate simply maps the transformation 
	% implication__transform_item_and_context onto every member of the 
	% input list.
implication__transform_over_list([], []).

implication__transform_over_list([In|Ins], [Out|Outs]) :-
	implication__transform_item_and_context(In, Out),
	implication__transform_over_list(Ins, Outs).

% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - %

	% implication__transform_item_and_context/2

	% Inlines the implication and equivalence operators
	% Note that the Context is unchanged and is just passed
	% straight through.
	% It simply strips off the Context and passes the
	% item on to implication__transform_item/2
implication__transform_item_and_context((Item_In - Context_In),
			(Item_Out - Context_In)) :-
	implication__transform_item(Item_In, Item_Out).

% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - %

	% implication__transform_item/2

	% Inlines the implication and equivalence operators.
	% If the item is a clause, it pulls out the goal and
	% transforms it, otherwise the item passes through
	% unchanged.
implication__transform_item(Item_In, Item_Out) :-
	(
		Item_In = clause(Varset, Sym_name, Terms, Goal_In)
	->
		(
		implication__transform_goal(Goal_In, Goal_Out),
		Item_Out = clause(Varset, Sym_name, Terms, Goal_Out)
		)
	;
		Item_Out = Item_In
	).	

% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - %

implication__transform_goal(Goal_In, Goal_Out) :-
	(
% Handle Implication...
	% Default version: implicit existential quantification
		Goal_In  = implies(P, Q)
	->
		(
		implication__transform_goal(P, P1),
		implication__transform_goal(Q, Q1),
		Goal_Out = not([], (P1, not([], Q1)))
		)
	;
	% Implication with explicit existential quantification
		Goal_In  = some(_, implies(P, Q))
	->
		(
		implication__transform_goal(P, P1),
		implication__transform_goal(Q, Q1),
		Goal_Out = not([], (P1, not([], Q1)))
		)
	;
	% Implication with explicit universal quantification
		Goal_In  = all(_, implies(P, Q))
	->
		(
		implication__transform_goal(P, P1),
		implication__transform_goal(Q, Q1),
		Goal_Out = not([], (P1, not([], Q1)))
		)
	;

% Handle Equivalence...
	% Default version: implicit existential quantification
		Goal_In  = equivalent(P, Q)
	->
		(
		implication__transform_goal(implies(P,Q), Forward),
		implication__transform_goal(implies(Q,P), Backward),
		Goal_Out = (Forward, Backward)
		)
	;
	% Equivalence with explicit existential quantification
		Goal_In  = some(_, equivalent(P, Q))
	->
		(
		implication__transform_goal(implies(P,Q), Forward),
		implication__transform_goal(implies(Q,P), Backward),
		Goal_Out = (Forward, Backward)
		)
	;
	% Equivalence with explicit universal quantification
		Goal_In  = all(_, equivalent(P, Q))
	->
		(
		implication__transform_goal(P, P1),
		implication__transform_goal(Q, Q1),
		Goal_Out = not([], ((P1 ; Q1), (not([], P1) ; not([],Q1))))
		)
	;

% Handle negation...	
	Goal_In  = not(_, implies(P, Q))
	->
		(
		implication__transform_goal(P, P1),
		implication__transform_goal(Q, Q1),
		Goal_Out = (P1, not([],Q1))
		)
	;
		Goal_In  = not(_, equivalent(P, Q))
	->
		(
		implication__transform_goal(P, P1),
		implication__transform_goal(Q, Q1),
		Goal_Out = ((P1, not([], Q1)) ; (Q1, not([], P1)))
		)
	;
% If all else fails let the goal fall through without change...
		Goal_Out = Goal_In
	).

% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - %
