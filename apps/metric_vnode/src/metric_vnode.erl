-module(metric_vnode).
-behaviour(riak_core_vnode).

-include_lib("riak_core/include/riak_core_vnode.hrl").

-export([start_vnode/1,
         init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         repair/3,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
		 compact/1,
         handle_info/2,
         handle_exit/3]).

-define(WEEK, 604800). %% Seconds in a week.
-export([mput/3, put/5, get/4]).

-ignore_xref([
              start_vnode/1,
              put/5,
              mput/3,
              get/4,
              repair/4,
			  compact/1,
              handle_info/2,
              repair/3
             ]).

-record(state, {
          partition,
          node,
          mstore=gb_trees:empty(),
          tbl,
		  tt,
          ct,
          dir
         }).

-define(MASTER, metric_vnode_master).

%% API
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

init([Partition]) ->
	Ps = integer_to_list(Partition),
    P = list_to_atom(Ps),
    CT = case application:get_env(metric_vnode, cache_points) of
             {ok, V} ->
                 V;
             _ ->
                 10
         end,
    DataDir = case application:get_env(riak_core, platform_data_dir) of
                  {ok, DD} ->
                      DD;
                  _ ->
                      "data"
              end,
    PartitionDir = [DataDir, $/,  integer_to_list(Partition)],
    {ok, #state { partition = Partition,
                  node = node(),
                  tbl = ets:new(P, [public, bag]),
                  tt = ets:new(list_to_atom(Ps ++ "_times"), [public, ordered_set]),
                  ct = CT,
                  dir = PartitionDir
                }}.

repair(IdxNode, {Bucket, Metric}, {Time, Obj}) ->
    riak_core_vnode_master:command(IdxNode,
                                   {repair, Bucket, Metric, Time, Obj},
                                   ignore,
                                   ?MASTER).


put(Preflist, ReqID, Bucket, Metric, {Time, Values}) when is_list(Values) ->
    put(Preflist, ReqID, Bucket, Metric, {Time, << <<1, V:64/signed-integer>> || V <- Values >>});

put(Preflist, ReqID, Bucket, Metric, {Time, Value}) when is_integer(Value) ->
    put(Preflist, ReqID, Bucket, Metric, {Time, <<1, Value:64/signed-integer>>});

put(Preflist, ReqID, Bucket, Metric, {Time, Value}) ->
    riak_core_vnode_master:command(Preflist,
                                   {put, Bucket, Metric, {Time, Value}},
                                   {raw, ReqID, self()},
                                   ?MASTER).

mput(Preflist, ReqID, Data) ->
    riak_core_vnode_master:command(Preflist,
                                   {mput, Data},
                                   {raw, ReqID, self()},
                                   ?MASTER).

get(Preflist, ReqID, {Bucket, Metric}, {Time, Count}) ->
    riak_core_vnode_master:command(Preflist,
                                   {get, ReqID, Bucket, Metric, {Time, Count}},
                                   {fsm, undefined, self()},
                                   ?MASTER).

%% Sample command: respond to a ping
handle_command(ping, _Sender, State) ->
    {reply, {pong, State#state.partition}, State};

handle_command({repair, Bucket, Metric, Time, Value}, _Sender, State) ->
    State1 = empty_cache({Bucket, Metric}, State),
    State2 = do_put(Bucket, Metric, Time, Value, State1),
    {noreply, State2};

handle_command({mput, Data}, _Sender, State) ->
    State1 = lists:foldl(fun({Bucket, Metric, Time, Value}, SAcc) ->
                                 do_put(Bucket, Metric, Time, Value, SAcc)
                         end, State, Data),
    {reply, ok, State1};

handle_command({put, Bucket, Metric, {Time, Value}}, _Sender, State) ->
    State1 = do_put(Bucket, Metric, Time, Value, State),
    {reply, ok, State1};

handle_command({get, ReqID, Bucket, Metric, {Time, Count}}, _Sender,
               #state{partition=Partition, node=Node} = State) ->
  State1 = empty_cache({Bucket, Metric}, State),
    {D, State2} = case get_set(Bucket, State1) of
                      {ok, {{Resolution, MSet}, S2}} ->
                          {ok, Data} = mstore:get(MSet, Metric, Time, Count),
                          {{Resolution, Data}, S2};
                      _ ->
                          Resolution = dalmatiner_opt:get(
                                         <<"buckets">>, Bucket, <<"resolution">>,
                                         {metric_vnode, resolution}, 1000),
                          {{Resolution, mmath_bin:empty(Count)}, State1}
                  end,
    {reply, {ok, ReqID, {Partition, Node}, D}, State2};

handle_command(_Message, _Sender, State) ->
    {noreply, State}.

handle_handoff_command(?FOLD_REQ{foldfun=Fun, acc0=Acc0}, _Sender, State) ->
    State1 = empty_cache(State),
    Ts = gb_trees:to_list(State1#state.mstore),
    Acc = lists:foldl(fun({Bucket, {_, MStore}}, AccL) ->
                              F = fun(Metric, Time, V, AccIn) ->
                                          Fun({Bucket, Metric}, {Time, V}, AccIn)
                                  end,
                              mstore:fold(MStore, F, AccL)
                      end, Acc0, Ts),
    {reply, Acc, State1};

handle_handoff_command(_Message, _Sender, State) ->
    {noreply, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(Data, State) ->
    {{Bucket, Metric}, {T, V}} = binary_to_term(Data),
    State1 = do_put(Bucket, Metric, T, V, State),
    {reply, ok, State1}.

encode_handoff_item(Key, Value) ->
    term_to_binary({Key, Value}).

is_empty(State = #state{tbl = T}) ->
    R = ets:first(T) == '$end_of_table' andalso
        calc_empty(gb_trees:iterator(State#state.mstore)),
    {R, State}.

calc_empty(I) ->
    case gb_trees:next(I) of
        none ->
            true;
        {_, {_, MSet}, I2} ->
            gb_sets:is_empty(mstore:metrics(MSet))
                andalso calc_empty(I2)
    end.

delete(State = #state{partition=Partition, tbl=T, tt = TT}) ->
    ets:delete_all_objects(T),
    ets:delete_all_objects(TT),
    DataDir = case application:get_env(riak_core, platform_data_dir) of
                  {ok, DD} ->
                      DD;
                  _ ->
                      "data"
              end,
    PartitionDir = [DataDir, $/,  integer_to_list(Partition)],
    gb_trees:map(fun(Bucket, {_, MSet}) ->
                         mstore:delete(MSet),
                         file:del_dir([PartitionDir, $/, Bucket])
                 end, State#state.mstore),
    {ok, State#state{mstore=gb_trees:empty()}}.

handle_coverage({metrics, Bucket}, _KeySpaces, _Sender,
                State = #state{partition=Partition, node=Node}) ->
    State1 = empty_cache(State),
    {Ms, State2} = case get_set(Bucket, State1) of
                       {ok, {{_, M}, S2}} ->
                           {mstore:metrics(M), S2};
                       _ ->
                           {gb_sets:new(), State1}
                   end,
    Reply = {ok, undefined, {Partition, Node}, Ms},
    {reply, Reply, State2};

handle_coverage(list, _KeySpaces, _Sender,
                State = #state{partition=Partition, node=Node}) ->
    State1 = empty_cache(State),
    DataDir = case application:get_env(riak_core, platform_data_dir) of
                  {ok, DD} ->
                      DD;
                  _ ->
                      "data"
              end,
    PartitionDir = [DataDir, $/,  integer_to_list(Partition)],
    Buckets1 = case file:list_dir(PartitionDir) of
                   {ok, Buckets} ->
                       gb_sets:from_list([list_to_binary(B) || B <- Buckets]);
                   _ ->
                       gb_sets:new()
               end,
    Reply = {ok, undefined, {Partition, Node}, Buckets1},
    {reply, Reply, State1};

handle_coverage({delete, Bucket}, _KeySpaces, _Sender,
                State = #state{partition=Partition, node=Node, dir=Dir}) ->
    State1 = empty_cache(State),
    {R, State2} = case get_set(Bucket, State1) of
                      {ok, {{_, MSet}, S1}} ->
                          mstore:delete(MSet),
                          file:del_dir([Dir, $/, Bucket]),
                          MStore = gb_trees:delete(Bucket, S1#state.mstore),
                          {ok, S1#state{mstore = MStore}};
                      _ ->
                          {not_found, State}
                  end,
    Reply = {ok, undefined, {Partition, Node}, R},
    {reply, Reply, State2};

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_info(_Msg, State)  ->
    {ok, State}.

handle_exit(_PID, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    State1 = empty_cache(State),
    gb_trees:map(fun(_, {_, MSet}) ->
                         mstore:close(MSet)
                 end, State1#state.mstore),
    ok.

new_store(Partition, Bucket) ->
    DataDir = dalmatiner_opt:get(<<"buckets">>, Bucket, <<"data_dir">>,
                                 {riak_core, platform_data_dir}, "data"),
    PartitionDir = [DataDir | [$/ |  integer_to_list(Partition)]],
    BucketDir = [PartitionDir, [$/ | binary_to_list(Bucket)]],
    file:make_dir(PartitionDir),
    file:make_dir(BucketDir),
    PointsPerFile = dalmatiner_opt:get(<<"buckets">>, Bucket,
                                       <<"points_per_file">>,
                                       {metric_vnode, points_per_file}, ?WEEK),
    Resolution = dalmatiner_opt:get(<<"buckets">>, Bucket, <<"resolution">>,
                                    {metric_vnode, resolution}, 1000),
    {ok, MSet} = mstore:new(PointsPerFile, BucketDir),
    {Resolution, MSet}.

do_put(Bucket, Metric, Time, Value, State = #state{tt = TT, tbl = T, ct = CT}) ->
    BM = {Bucket, Metric},
	case ets:lookup(TT, BM) of
		[{_, _First}]
		  when Time < _First  ->
			do_write(Bucket, Metric,Time, Value, State);
		[{_, _First}]
		  when (Time - _First) < CT  ->
			ets:insert(T, {BM, Time, Value}),
            State;
		[] ->
			ets:insert(TT, {BM, Time}),
			ets:insert(T, {BM, Time, Value}),
            State;
		_ ->
			State1 = empty_cache(BM, State),
			ets:insert(TT, {BM, Time}),
			ets:insert(T, {BM, Time, Value}),
			State1
    end.

empty_cache(State = #state{tt = TT}) ->
	ets:foldl(fun({BM, _}, SAcc) ->
					  empty_cache(BM, SAcc)
			  end, State, TT).

empty_cache({Bucket, Metric} = BM, State = #state{tbl = T, tt = TT}) ->
	ets:delete(TT, BM),
	case lists:sort(ets:lookup(T, BM)) of
		[] ->
			State;
		L1 ->
			ets:match_delete(T, {BM, '_', '_'}),
			{Time, Data} = compact(L1),
			do_write(Bucket, Metric, Time, Data, State)
	end.

compact([{_, T, V} | R]) ->
	%%io:format(user, "compact(~p, ~p, ~p).~n", [R, T, V]),
	compact(R, T, V).

compact([], T, Acc) ->
	{T, Acc};

compact([{_, T, V} | R], T0, Acc)
  when T == (T0 + byte_size(Acc) div 9) ->
	compact(R, T0, <<Acc/binary, V/binary>>);

compact([{_, T, V} | R], T0, Acc) 
  when T > (T0 + byte_size(Acc) div 9) ->
	E = mmath_bin:empty(T - (T0 + byte_size(Acc) div 9)),
	compact(R, T0, <<Acc/binary, E/binary, V/binary>>);

compact([{_, T, V} | R], T0, Acc) ->
	E = mmath_bin:empty(T - T0),
	V1 = <<E/binary, V/binary>>,
	compact(R, T0, mmath_comb:merge([Acc, V1])).

do_write(Bucket, Metric, Time, Value, State) ->
    {{R, MSet}, State1} = get_or_create_set(Bucket, State),
    MSet1 = mstore:put(MSet, Metric, Time, Value),
    Store1 = gb_trees:update(Bucket, {R, MSet1}, State1#state.mstore),
    State1#state{mstore=Store1}.

get_set(Bucket, State=#state{mstore=Store}) ->
    case gb_trees:lookup(Bucket, Store) of
        {value, MSet} ->
            {ok, {MSet, State}};
        none ->
            case bucket_exists(State#state.partition, Bucket) of
                true ->
                    R = new_store(State#state.partition, Bucket),
                    Store1 = gb_trees:insert(Bucket, R, Store),
                    {ok, {R, State#state{mstore=Store1}}};
                _ ->
                    {error, not_found}
            end
    end.

get_or_create_set(Bucket, State=#state{mstore=Store}) ->
    case get_set(Bucket, State) of
        {ok, R} ->
            R;
        {error, not_found} ->
            MSet = new_store(State#state.partition, Bucket),
            Store1 = gb_trees:insert(Bucket, MSet, Store),
            {MSet, State#state{mstore=Store1}}
    end.

bucket_exists(Partition, Bucket) ->
    DataDir = case application:get_env(riak_core, platform_data_dir) of
                  {ok, DD} ->
                      DD;
                  _ ->
                      "data"
              end,
    PartitionDir = [DataDir | [$/ |  integer_to_list(Partition)]],
    BucketDir = [PartitionDir, [$/ | binary_to_list(Bucket)]],
    filelib:is_dir(BucketDir).
