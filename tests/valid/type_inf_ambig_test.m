% This module tests that type inference checks for ambiguities
% predicate-at-a-time rather than clause-at-a-time.
% Mercury 0.6 failed this test.

:- module type_inf_ambig_test .

:- interface.
:- import_module io, int.

:- pred main(io__state::di, io__state::uo) is det.

:- implementation.

:- type l1 ---> (nil ; f(int,l1)).

:- type l2 ---> (nil ; somethingelse).

main --> {foo(L), g(L)}.

%% :- pred g(l1).	%1
:- mode g(in) is det.

g(nil).		%2
g(f(_,R)) :- g(R).	%2

%% g(L) :-		%3
%% 	L = nil -> true	%3
%% 	;		%3
%% 	L = f(_,R), g(R). %3


:- pred foo(l1).
:- mode foo(out) is det.

foo(f(1,f(2,nil))).


