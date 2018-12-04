%#define FDB_KEYSEL_LAST_LESS_THAN(k, l) k, l, 0, 0
%#define FDB_KEYSEL_LAST_LESS_OR_EQUAL(k, l) k, l, 1, 0
%#define FDB_KEYSEL_FIRST_GREATER_THAN(k, l) k, l, 1, 1
%#define FDB_KEYSEL_FIRST_GREATER_OR_EQUAL(k, l) k, l, 0, 1
%key_name, key_name_length, x_or_equal, offset
%We can ignore the length param

-record(keysel, {key_name, or_equal, offset}).
-define(FDB_KEYSEL_LAST_LESS_THAN(K), #keysel{key_name = K, or_equal = false, offset = 0}).
-define(FDB_KEYSEL_LAST_LESS_OR_EQUAL(K), #keysel{key_name = K, or_equal = true, offset = 0}).
-define(FDB_KEYSEL_FIRST_GREATER_THAN(K), #keysel{key_name = K, or_equal = true, offset = 1}).
-define(FDB_KEYSEL_FIRST_GREATER_OR_EQUAL(K), #keysel{key_name = K, or_equal = false, offset = 1}).

-record(select, {
   'begin' = nil,
   'end' = nil,
   limit = 0,
   target_bytes = 0,
   streaming_mode = iterator,
   iteration = 1,
   is_snapshot = false,
   is_reverse = false}).

-record(iterator, {
   tx,
   iteration,
   data = [],
   select,
   more = false}).

-type fdb_version() :: pos_integer().
-type fdb_errorcode() :: pos_integer().
-type fdb_cmd_result() :: ok | {error, fdb_errorcode()}|{error,nif_not_loaded}.
%-type fdb_qry_result() :: {ok, term()} | {error, fdb_errorcode()}.
-type fdb_database() :: {db, term()}.
-type fdb_transaction() :: {tx, term()}.
-type fdb_handle() :: fdb_database() | fdb_transaction().
-type fdb_key() :: term().
-type fdb_key_value() :: {fdb_key(), term()}.


