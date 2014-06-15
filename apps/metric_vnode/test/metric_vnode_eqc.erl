-module(metric_vnode_eqc).

-ifdef(TEST).
-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_fsm.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").
-compile(export_all).
-define(DIR, ".qcdata").
-define(T, gb_trees).
-define(V, metric_vnode).
-define(M, <<"metric">>).

%%%-------------------------------------------------------------------
%%% Generators
%%%-------------------------------------------------------------------

non_z_int() ->
    ?SUCHTHAT(I, int(), I =/= 0).

offset() ->
    choose(0, 5000).

tree_set(Tr, _T, []) ->
    Tr;

tree_set(Tr, T, [V | R]) ->
    Tr1 = ?T:enter(T, V, Tr),
    tree_set(Tr1, T+1, R).

new() ->
    {ok, S} = ?V:init([0]),
    T = ?T:empty(),
    {S, T}.

repair({S, Tr}, T, V) ->
    Command = {repair, ?M, T, V},
    {noreply, S1} = ?V:handle_command(Command, sender, S),
    Tr1 = tree_set(Tr, T, V),
    {S1, Tr1}.

put({S, Tr}, T, V) ->
    ReqID = T,
    Req = {ReqID, something},
    Command = {put, Req, ?M, {T, V}},
    {reply, {ok, ReqID}, S1} = ?V:handle_command(Command, sender, S),
    Tr1 = tree_set(Tr, T, V),
    {S1, Tr1}.

get(S, T, C) ->
    ReqID = T,
    Command = {get, ReqID, ?M, {T, C}},
    {reply, {ok, ReqID, _, Data}, _S1} = ?V:handle_command(Command, sender, S),
    Data.

vnode() ->
    ?SIZED(Size,vnode(Size)).

non_empty_list(T) ->
    ?SUCHTHAT(L, list(T), L =/= []).

vnode(Size) ->
    ?LAZY(oneof([{call, ?MODULE, new, []} || Size == 0]
                ++ [{call, ?MODULE, put, [vnode(Size-1), offset(), non_empty_list(non_z_int())]}  || Size > 0]
                ++ [{call, ?MODULE, repair, [vnode(Size-1), offset(), non_empty_list(non_z_int())]}  || Size > 0]
               )).
%%%-------------------------------------------------------------------
%%% Properties
%%%-------------------------------------------------------------------

prop_gb_comp() ->
    ?FORALL(D, vnode(),
            begin
                os:cmd("rm -r data"),
                os:cmd("mkdir data"),
                {S, T} = eval(D),
                List = ?T:to_list(T),
                List1 = [{get(S, Time, 1), V} || {Time, V} <- List],
                List2 = [{unlist(mstore_bin:to_list(Vs)), Vt} || {Vs, Vt} <- List1],
                List3 = [true || {_V, _V} <- List2],
                Len = length(List),
                length(List1) == Len andalso
                    length(List2) == Len andalso
                    length(List3) == Len
            end
           ).

prop_is_empty() ->
    ?FORALL(D, vnode(),
            begin
                os:cmd("rm -r data"),
                os:cmd("mkdir data"),
                {S, T} = eval(D),
                {Empty, _S1} = ?V:is_empty(S),
                TreeEmpty = ?T:is_empty(T),
                if
                    Empty == TreeEmpty ->
                        ok;
                    true ->
                        io:format(user, "~p == ~p~n", [S, T])
                end,
                Empty == TreeEmpty
            end).

prop_empty_after_delete() ->
    ?FORALL(D, vnode(),
            begin
                os:cmd("rm -r data"),
                os:cmd("mkdir data"),
                {S, _T} = eval(D),
                {ok, S1} = ?V:delete(S),
                {Empty, _S3} = ?V:is_empty(S1),
                Empty == true
            end).

prop_handoff() ->
    ?FORALL(D, vnode(),
            begin
                os:cmd("rm -r data"),
                os:cmd("mkdir data"),
                {S, _T} = eval(D),
                Fun = fun(K, V, A) ->
                              [?V:encode_handoff_item(K, V) | A]
                      end,
                FR = ?FOLD_REQ{foldfun=Fun, acc0=[]},
                {reply, L, S1} = ?V:handle_handoff_command(FR, self(), S),
                L1 = lists:sort(L),
                {ok, C} = ?V:init([1]),
                C1 = lists:foldl(fun(Data, SAcc) ->
                                        {reply, ok, SAcc1} = ?V:handle_handoff_data(Data, SAcc),
                                        SAcc1
                                end, C, L1),
                {reply, Lc, C2} = ?V:handle_handoff_command(FR, self(), C1),
                Lc1 = lists:sort(Lc),
                {reply, {ok, _, _, Ms}, _} =
                    ?V:handle_coverage(metrics, all, self(), S1),
                {reply, {ok, _, _, MsC}, _} =
                    ?V:handle_coverage(metrics, all, self(), C2),
                Lc1 == L1 andalso
                    gb_sets:to_list(MsC) == gb_sets:to_list(Ms)

            end).

%%%-------------------------------------------------------------------
%%% Helper
%%%-------------------------------------------------------------------

unlist([E]) ->
    E.

-define(EQC_NUM_TESTS, 100).
-include("eqc_helper.hrl").
-endif.
-endif.