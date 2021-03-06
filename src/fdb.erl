-module(fdb).
-export([init/0, init/1]).
-export([api_version/1, open/0]).
-export([get/2, get/3, get_range/3, set/3, fold/4]).
-export([clear/2, clear_range/3]).
-export([transact/2]).
-export([init_and_open/0, init_and_open/1]).
-export([maybe_do/1]).

-behaviour(gen_fdb).

-define (FUTURE_TIMEOUT, 5000).
-include("../include/fdb.hrl").

maybe_do(Fs) ->
  Wrapped = lists:map(fun wrap_fdb_result_fun/1, Fs),
  maybe:do(Wrapped).

wrap_fdb_result_fun(F) ->
  case erlang:fun_info(F, arity) of
   {arity, 0} -> fun( ) -> handle_fdb_result(F()) end;
   {arity, 1} -> fun(X) -> handle_fdb_result(F(X)) end;
   _ -> throw({error, unsupported_arity })
  end.

%% @doc Loads the native FoundationDB library file from a certain location
-spec init(SoFile::list())-> ok | {error, term()}.
%% @end
init(SoFile) -> fdb_nif:init(SoFile).

%% @doc Loads the native FoundationDB library file from  `priv/fdb_nif.so`
-spec init()-> ok | {error, term()}.
%% @end
init() ->
  init("priv/fdb_nif").

%% @doc Specify the API version we are using
%%
%% This function must be called after the init, and before any other function in
%% this library is called.
-spec api_version(fdb_version()) -> fdb_cmd_result().
%% @end
api_version(Version) ->
  handle_fdb_result(fdb_nif:fdb_select_api_version(Version)).

%% @doc  Opens the given database 
%% 
%% (or the default database of the cluster indicated by the fdb.cluster file in a 
%% platform-specific location, if no cluster_file or database_name is provided).  
%% Initializes the FDB interface as required.
-spec open() -> fdb_database().
%% @end
open() ->
  maybe_do([
  fun () -> fdb_nif:fdb_setup_network() end,
  fun () -> fdb_nif:fdb_run_network() end,
  fun () -> fdb_nif:fdb_create_cluster() end,
  fun (ClF) -> future_get(ClF, cluster) end,
  fun (ClHandle) -> fdb_nif:fdb_cluster_create_database(ClHandle) end,
  fun (DatabaseF) -> future_get(DatabaseF, database) end,
  fun (DbHandle) -> {ok,{db, DbHandle}} end]).

%% @doc Initializes the driver and returns a database handle
-spec init_and_open() -> fdb_database().
%% end
init_and_open() ->
  init(),
  api_version(100),
  maybe_do([
    fun() -> open() end,
    fun(DB) -> DB end
  ]).

%% @doc Initializes the driver and returns a database handle
-spec init_and_open(SoFile::list()) -> fdb_database().
%% end
init_and_open(SoFile) ->
  init(SoFile),
  api_version(100),
  maybe_do([
    fun() -> open() end,
    fun(DB) -> DB end
  ]).

%% @doc Gets a value using a key or multiple values using a selector
%%
%% Returns `not_found` for the single value if the key is not found, 
-spec get(fdb_handle(), fdb_key()|#select{}) -> (term() | not_found | [term()]).
%% @end
get(DB={db, _}, Select = #select{}) ->
  transact(DB, fun(Tx) -> get(Tx, Select) end);
get(Tx={tx, _}, Select = #select{}) ->
  Fun = fun(Batch, {ok, Acc0}) ->
                {ok, [Batch|Acc0]}
        end,
  case fold(Tx, Fun, {ok, []}, Select) of
      {ok, AccFinal} ->
          % the result is a list of proplists, so this is
          % safe and the most memory efficient option
          lists:flatten(lists:reverse(AccFinal));
      Error ->
          Error
  end;
get(FdbHandle, Key) -> 
  get(FdbHandle, Key, not_found).

fold(DB={db, _Database}, Fun, Acc, Select=#select{}) ->
    transact(DB, fun(Tx) -> fold(Tx, Fun, Acc, Select) end);
fold(Tx={tx, _}, Fun, Acc, Select=#select{}) ->
    Iterator = bind(Tx, Select),
    fold_iterator(Fun, Acc, Iterator).

fold_iterator(Fun, Acc, Iterator) ->
    case next(Iterator) of
        Next=#iterator{} ->
            Acc2 = Fun(Next#iterator.data, Acc),
            if
                Next#iterator.more ->
                    fold_iterator(Fun, Acc2, Next);
                true ->
                    Acc2
            end;
        Error ->
            Error
    end.

%% @doc Gets a range of key-value tuples where `begin <= X < end`
-spec get_range(fdb_handle(), fdb_key(),fdb_key()) -> ([term()]|{error,nif_not_loaded}).
%% For inclusive range [Begin, End], use this selector format.
%%
%% fdb:get_range(Db, Begin, fdb_keysel:first_greater_than(End)).
%%
%% In English, this expression means: Give me all the keys that start with Begin and exclude
%% everything that is greater than End.
%% @end
get_range(Handle, Begin, End) ->
  get(Handle, #select{'begin' = Begin, 'end' = End}).


%% @doc Gets a value using a key, falls back to a default value if not found
-spec get(fdb_handle(), fdb_key(), term()) -> term().
%% @end
get(DB={db, _Database}, Key, DefaultValue) ->
  transact(DB, fun(Tx) -> get(Tx, Key, DefaultValue) end);
get({tx, Tx}, Key, DefaultValue) ->
  maybe_do([
  fun()-> fdb_nif:fdb_transaction_get(Tx, Key) end,
  fun(GetF) -> future_get(GetF, value) end,
  fun(Result) -> case Result of
      not_found -> DefaultValue;
      _ -> Result
   end
  end]).

%% @doc Binds a range of data to an iterator; use `fdb:next` to iterate it
-spec bind(fdb_handle(), #select{}) -> #iterator{}.
%% @end
bind(DB={db, _}, Select = #select{}) ->
  transact(DB, fun(Tx) -> bind(Tx, Select) end);
bind({tx, Transaction}, Select = #select{}) ->
  #iterator{tx = Transaction, select = Select, iteration = Select#select.iteration}.

%% @doc Get data of an iterator; returns the iterator or `done` when finished
-spec next(#iterator{}) -> (#iterator{}).
%% @end
next(Iterator = #iterator{tx = Transaction, iteration = Iteration, select = Select}) ->
  {BeginKey, BeginIsEq, BeginOfs} = begin_keysel_params(Select#select.'begin'),
  {EndKey, EndIsEq, EndOfs} = end_keysel_params(Select#select.'end'),
  %io:format("~p~n", [Iterator]),
  maybe_do([
   fun() -> fdb_nif:fdb_transaction_get_range(Transaction, 
      BeginKey, BeginIsEq, BeginOfs,
      EndKey, EndIsEq, EndOfs,
      Select#select.limit, 
      Select#select.target_bytes, 
      Select#select.streaming_mode, 
      Iteration, 
      Select#select.is_snapshot, 
      Select#select.is_reverse) end,
   fun(F) -> {fdb_nif:fdb_future_is_ready(F),F} end,
   fun(Ready) -> wait_non_blocking(Ready) end, 
   fun(F) -> future_get(F, keyvalue_array) end,
   fun(#{data := EncodedData,
         more := More}) -> 
     %io:format("keyvalue ~p~n", [Map]),
     ReturnData = lists:map(fun unpack_array_row/1, EncodedData),
     NextIteration = Iteration+1,
     case EncodedData of
         [] ->
             Iterator#iterator{
               data = ReturnData,
               iteration = NextIteration,
               more = false};
        _ ->
            %% the C# client does this in addition to advancing the iterator:
            %% beginSelector = KeySelector.FirstGreaterThan(data.Last);
            %% This isn't documented anywhere in fdb :(
            {LastKey, _} = lists:last(EncodedData),
            NewSelect = Select#select{'begin' = ?FDB_KEYSEL_FIRST_GREATER_THAN(LastKey)},
            Iterator#iterator{
              select = NewSelect,
              data = ReturnData,
              iteration = NextIteration,
              more = More}
     end end]).

unpack_array_row({X,Y}) -> 
  {X, Y}.

begin_keysel_params(#keysel{key_name=KeyName, or_equal=OrEqual, offset=Offset}) -> {KeyName,OrEqual,Offset};
begin_keysel_params(Key) -> begin_keysel_params(#keysel{key_name=Key, or_equal=false, offset=1}). % default inclusive

end_keysel_params(#keysel{key_name=KeyName, or_equal=OrEqual, offset=Offset}) -> {KeyName,OrEqual,Offset};
end_keysel_params(Key) -> end_keysel_params(#keysel{key_name=Key, or_equal=false, offset=1}). % default exclusive

%% @doc sets a key and value
%% Existing values will be overwritten
-spec set(fdb_handle(), fdb_key(), term()) -> fdb_cmd_result().
%% @end
set({db, Database}, Key, Value) ->
  transact({db, Database}, fun (Tx)-> set(Tx, Key, Value) end);
set({tx, Tx}, Key, Value) ->
  ErrCode = fdb_nif:fdb_transaction_set(Tx, Key, Value),
  handle_fdb_result(ErrCode).

%% @doc Clears a key and it's value
-spec clear(fdb_handle(), fdb_key()) -> fdb_cmd_result().
%% @end
clear({db, Database}, Key) ->
  transact({db, Database}, fun (Tx)-> clear(Tx, Key) end);
clear({tx, Tx}, Key) ->
  ErrCode = fdb_nif:fdb_transaction_clear(Tx, Key),
  handle_fdb_result(ErrCode).

%% @doc Clears all keys where `begin <= X < end`
-spec clear_range(fdb_handle(), fdb_key(), fdb_key()) -> fdb_cmd_result().
%% @end
clear_range({db, Database}, Begin, End) ->
  transact({db, Database}, fun (Tx)-> clear_range(Tx, Begin, End) end);
clear_range({tx, Tx}, Begin, End) ->
  ErrCode = fdb_nif:fdb_transaction_clear_range(Tx, Begin, End),
  handle_fdb_result(ErrCode).

-spec transact(fdb_database(), fun((fdb_transaction())->term())) -> term().
transact({db, DbHandle}, DoStuff) ->
  CommitResult = attempt_transaction(DbHandle, DoStuff),
  handle_transaction_attempt(CommitResult).

attempt_transaction(DbHandle, DoStuff) ->
  maybe_do([
  fun() -> fdb_nif:fdb_database_create_transaction(DbHandle) end,
  fun(Tx) -> 
      Result = DoStuff({tx, Tx}),
      ApplySelf = fun() -> attempt_transaction(DbHandle, DoStuff) end,
      CommitF = fdb_nif:fdb_transaction_commit(Tx), 
      {future(CommitF), Tx, Result, ApplySelf}
     end
  ]).

handle_transaction_attempt({ok, _Tx, Result, _ApplySelf}) -> Result;
handle_transaction_attempt({{error, Err}, Tx, _Result, _ApplySelf}) ->
  OnErrorF = fdb_nif:fdb_transaction_on_error(Tx, Err),
  maybe_do([
    fun () -> future(OnErrorF) end
  ]).

handle_fdb_result({0, RetVal}) -> {ok, RetVal};
handle_fdb_result({error, 2009}) -> ok;
handle_fdb_result({error, network_already_running}) -> ok;
handle_fdb_result({Err = {error, _}, _F}) -> Err;
handle_fdb_result(Other) -> Other.

future(F) -> future_get(F, none).

future_get(F, FQuery) -> 
  maybe_do([
    fun() -> {fdb_nif:fdb_future_is_ready(F), F} end,
    fun(Ready) -> wait_non_blocking(Ready) end,
    fun() -> fdb_nif:fdb_future_get_error(F) end,
    fun() -> get_future_property(F, FQuery) end
  ]).

get_future_property(_F,none) ->
  ok;
get_future_property(F,FQuery) ->
  FullQuery = list_to_atom("fdb_future_get_" ++ atom_to_list(FQuery)),
  apply(fdb_nif, FullQuery, [F]).

wait_non_blocking({false,F}) ->
  Ref = make_ref(),
  maybe_do([
  fun ()-> fdb_nif:send_on_complete(F,self(),Ref),
    receive
      Ref -> {ok, F}
      after ?FUTURE_TIMEOUT -> {error, timeout}
    end
  end]);
wait_non_blocking({true,F}) ->
  {ok, F}.
