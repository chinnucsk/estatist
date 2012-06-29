% @author Kozorezov Petr <petr.kozorezov@gmail.com>
% @copyright 2012 Kozorezov Petr
% @private
-module(estatist_core).
-behaviour(gen_server).

-define(SERVER, {global, ?MODULE}).

%%
%% API
%%
-export([
         start_link/1,
         stop/1,
         add_metric/3,
         delete_metric/1,
         update/2,
         get/3,
         select/3,
         select/4,
         test/0
        ]).

%%
%% gen_server callbacks
%%
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

%%
%% API
%%
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

stop(Reason) ->
    gen_server:call(?MODULE, {stop, Reason}).


-spec add_metric(Name, Scalarity, MetricTypes) -> ok | {error, term()} when
    Name        :: estatist:metric_name(),
    Scalarity   :: estatist:metric_scalarity(),
    MetricTypes :: estatist:metric_types().
add_metric(Name, Scalarity, MetricTypes) when is_atom(Name) and ((Scalarity == var) or (Scalarity == tbl)) ->
    try
        Context = init_metric(Scalarity, Name, MetricTypes),
        true = ets:insert_new(?MODULE, {Name, Scalarity, Context}), ok
    catch
        _:E -> {error, E}
    end;
add_metric(Name, Scalarity, MetricTypes) ->
    {error, {incorrect_metric, {Name, Scalarity, MetricTypes}}}.


-spec delete_metric(Name) -> ok when
    Name :: estatist:metric_name().
delete_metric(Name) ->
    true = ets:delete(?MODULE, Name), ok.


-spec update(MetricID, Value) -> ok | {error, term()} when
    MetricID :: estatist:metric_id(),
    Value :: estatist:metric_input_value().
update({Name, RowID}, Value) ->
    try
        CorrectRowID = correct_row_id(RowID),
        {Name, tbl, {Tid, MagicTuples}} = get_metric(Name),
        {RowName, Contexts} = get_insert_tbl_row(Tid, Name, CorrectRowID, MagicTuples),
        update_by_contexts({Name, RowName}, Contexts, Value), ok
    catch
        _:E -> {error, E}
    end;
update(Name, Value) ->
    try
        {Name, var, Contexts} = get_metric(Name),
        update_by_contexts(Name, Contexts, Value), ok
    catch
        _:E -> {error, E}
    end.


get({Name, RowID}, Type, Param) ->
    try
        {Name, tbl, {Tid, _}} = get_metric(Name),
        {RowName, Contexts} = get_tbl_row(Tid, correct_row_id(RowID)),
        get_from_contexts({Name, RowName}, Type, Param, Contexts)
    catch
        _:E -> {error, E}
    end;
get(Name, Type, Param) -> 
    try
        {Name, var, Contexts} = get_metric(Name),
        get_from_contexts(Name, Type, Param, Contexts)
    catch
        _:E -> {error, E}
    end.


-spec select(estatist:select_param(estatist:metric_name()), estatist:select_param(estatist:metric_type()), estatist:select_param(estatist:metric_type_param())) ->
    {ok, estatist:select_results()} | {error, term()}.
select(Names, Types, Params) ->
    F = fun({Name, var, Contexts}) ->
                get_from_contexts(Name, Types, Params, Contexts);
           ({Name, tbl, {_, _}}) ->
                select(Name, Types, Params, all)
        end,
    try 
        {ok, select(F, Names)}
    catch
        _:E -> {error, E}
    end.

% -spec select(estatist:select_names(), estatist:select_types(), estatist:select_params(), estatist:select_row_id()) ->
%     {ok, estatist:select_results()} | {error, term()}.
select(Names, Types, Params, RowID) ->
    F = fun({Name, tbl, {Tid, _}}) ->
                GetFromRow = fun(ID) ->
                                     case get_tbl_row(Tid, ID) of
                                         undefined ->
                                             undefined;
                                         {RowName, Contexts} ->
                                             get_from_contexts({Name, RowName}, Types, Params, Contexts)
                                     end
                             end,
                case RowID of
                    {id, ID} ->
                        GetFromRow(correct_row_id(ID));
                    first ->
                        GetFromRow(ets:first(Tid));
                    last ->
                        GetFromRow(ets:last(Tid));
                    {next, ID} ->
                        GetFromRow(ets:next(Tid, correct_row_id(ID)));
                    {prev, ID} ->
                        GetFromRow(ets:prev(Tid, correct_row_id(ID)));
                    all ->
                        F1 = fun({RowName, Contexts}, Acc) ->
                                    [{RowName, get_from_contexts({Name, RowName}, Types, Params, Contexts)} | Acc]
                            end,
                        lists:reverse(ets:foldl(F1, [], Tid));
                    List when is_list(List) ->
                        % lists:map(fun({id, ID}) -> GetFromRow(correct_row_id(ID)) end, List)
                        [select_1(V, GetFromRow) || V <- List]
                end;
           ({_, var, {_, _}}) ->
                undefined
        end,
    try 
        {ok, select(F, Names)}
    catch
        _:E -> {error, E}
    end.

select_1({id, ID}, GetFromRow) ->
    GetFromRow(correct_row_id(ID)).

%%
%% gen_server callbacks
%%

%% ets таблица в ней все метрики и их контексты
%% {name, var, [{metric_type, mod, context}]}
%% {name, tbl, {Tid, [{metric_type, mod, [options]}]}}
%% для табличных метрик создаются отдельные таблицы, в них
%% {row_name, [{metric_type, mod, context}]}

init(Options) ->

    ?MODULE = ets:new(?MODULE, [named_table, set, public]),

    Metrics = proplists:get_value(metrics, Options, []),

    InitMetric =
        fun({Name, Scalarity, MetricTypes}) when is_atom(Name) and ((Scalarity == var) or (Scalarity == tbl)) ->
                add_metric(Name, Scalarity, MetricTypes);
           (IncorrectMetric) ->
                throw({incorrect_metric, IncorrectMetric})
        end,

    lists:foreach(InitMetric, Metrics),

    {ok, undefined}.

handle_call({stop, Reason}, _, State) ->
    {stop, Reason, ok, State};

handle_call({add_tbl_row, Tid, Name, RowName, MagicTuples}, _, State) ->
    %% todo lookup
    Reply = case get_tbl_row(Tid, RowName) of
        undefined ->
            InitMetricType =
                fun(MagicTuple) ->
                        init_metric_type({Name, RowName}, MagicTuple)
                end,
            Value = {RowName, lists:map(InitMetricType, MagicTuples)},
            true = ets:insert_new(Tid, Value),
            {ok, Value};
        _ ->
            {error, dublicate}
    end,
    {reply, Reply, State};

handle_call(_, _, State) ->
    {noreply, ok, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({tick, {Mod, Context}}, State) ->
    Mod:tick(Context),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

%%
%% Local functions
%%
init_metric(var, Name, MetricTypes) ->
    InitMetricType =
        fun(MetricType) ->
                init_metric_type(Name, make_magic_tuple(MetricType))
        end,
    lists:map(InitMetricType, MetricTypes);

init_metric(tbl, _Name, MetricTypes) ->
    F = fun(MetricType) ->
                make_magic_tuple(MetricType)
        end,
    %%io:format(" init table \"~p\" ~p~n", [Name, MetricTypes]),
    {ets:new(?MODULE, [public, set]), lists:map(F, MetricTypes)}.

make_magic_tuple(MetricType) ->
    {SplittedMetricType, Options} = split_metric_type_option(MetricType),
    Mod = get_metric_type_module(SplittedMetricType),
    {SplittedMetricType, Mod, Options}.

init_metric_type(Name, {MetricType, Mod, Options}) ->
    {Context, Tick} = Mod:init(Name, Options),
    schedule_tick(Tick, Context, Mod),
    %%io:format(" init \"~p\" [~p]: ~p~n", [Name, MetricType, Context]),
    {MetricType, Mod, Context}.

get_metric_type_module(MetricType) ->
    list_to_atom("estatist_module_" ++ atom_to_list(MetricType)).

split_metric_type_option(MetricType) ->
    case MetricType of
        {MT, Opt} = T1 -> T1;
        MT -> {MT, []}
    end.    


select(F, all) ->
    ets:foldr(fun(Metric={Name, _ ,_}, Acc) -> [{Name, F(Metric)} | Acc] end, [], ?MODULE);
select(F, Names) when is_list(Names) ->
    % lists:map(fun(Name) -> {Name, F(get_metric(Name))} end, Names);
    [{Name, F(get_metric(Name))} || Name <- Names];
select(F, Name) when is_atom(Name) ->
    F(get_metric(Name)).

get_metric(Name) when is_atom(Name)->
    case ets:lookup(?MODULE, Name) of
        [] ->
            erlang:throw({unknown_metric, Name});
        [E] ->
            E
    end.

get_from_contexts(Name, all, Params, Contexts) ->
    F = fun({Type, Mod, Context}) ->
                {Type, Mod:get(Name, Context, Params)}
        end,
    lists:map(F, Contexts);
get_from_contexts(Name, Types, Params, Contexts) when is_list(Types) ->
    lists:zip(Types, [get_from_contexts(Name, Type, Params, Contexts) || Type <- Types]);
    %%lists:zip(Types, lists:map(fun(Type) -> get_from_contexts(Name, Type, Params, Contexts) end, Types));
get_from_contexts(Name, Type, Params, Contexts) when is_atom(Type) ->
    case lists:keyfind(Type, 1, Contexts) of
        false ->
            erlang:throw({type_for_this_metric_not_found, Name, Type});
        {Type, Mod, Context} ->
            Mod:get(Name, Context, Params)
    end.

update_by_contexts(Name, Contexts, Value) ->
    F = fun({_Type, Mod, Context}) ->
                Mod:update(Name, Context, Value)
        end,
    lists:foreach(F, Contexts),
    ok.


get_insert_tbl_row(Tid, Name, RowID, MagicTuples) ->
    case get_tbl_row(Tid, RowID) of
        undefined ->
            case add_tbl_row(Tid, Name, RowID, MagicTuples) of
                {ok, V} ->
                    V;
                {error, dublicate} ->
                    get_insert_tbl_row(Tid, Name, RowID, MagicTuples)
            end;
        V ->
            V
    end.

add_tbl_row(Tid, Name, RowName, MagicTuples) ->
    gen_server:call(?MODULE, {add_tbl_row, Tid, Name, RowName, MagicTuples}).

get_tbl_row(Tid, RowID) ->
    case ets:lookup(Tid, RowID) of
        [] ->
            undefined;
        [E] ->
            E
    end.


correct_row_id(Int) when is_integer(Int) ->
    integer_to_list(Int);
correct_row_id(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
correct_row_id(List) when is_list(List) ->
    % lists:map(fun(E) when is_integer(E) -> E;
    %              (_) ->
    %                   throw({incorrect_row_id, List})
    %           end, List);
    [correct_row_id_1(V, List) || V <- List];
correct_row_id(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
correct_row_id(E) ->
    throw({incorrect_row_id, E}).

correct_row_id_1(E, List) when is_integer(E) -> E;
correct_row_id_1(_, List) ->
    throw({incorrect_row_id, List}).

schedule_tick(undefined, _, _) ->
    ok;
schedule_tick(Tick, Context, Mod) ->
    {ok, _} = timer:send_interval(Tick, {tick, {Mod, Context}}), ok.

%% TODO auto test
test() ->
    Options = [
               {metrics, [
                          %%{online_counte1, var, [counter]},
                          {online_counter, var, [counter]},
                          {connects,       var, [meter]},
                          {game_requests,  tbl, [histogram, meter]},
                          {player_load,    var, [{meter, [{tick, 1000}]}, {histogram, [{size, 1000}]}]},
                          {player_save,    var, [meter, histogram]}
                         ]},
               {modules, [
                          {meter, estatist_module_meter}
                         ]}
              ],
    {ok, _Pid} = start_link(Options),
    ok = update(online_counter, 1),
    ok = update(player_save, 1),
    ok = update(player_save, 100),
    F = fun(V) ->
                timer:sleep(1000),
                io:format("select \"online_counter\": ~640p ~n", [select(online_counter, counter, count)]),
                io:format("select \"player_save\" meter: ~640p ~n", [select(player_save, meter, [one, five, fifteen])]),
                io:format("select \"player_save\" histogram: ~640p ~n", [select(player_save, histogram, [min, max, mean, count, stddev, p50, p95, p99])]),

                ok = update({game_requests, list_to_atom(integer_to_list(V))}, 100),
                io:format("select \"game_requests\" all: ~640p ~n", [select(game_requests, all, all)]),
                io:format("all: ~640p ~n", [select(all, all, all)])
                
        end,
    lists:foreach(F, [2,1,3,0]),
    stop(normal),
    ok.

