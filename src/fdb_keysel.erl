-module(fdb_keysel).
-export([last_less_than/1,
         last_less_or_equal/1,
         first_greater_than/1,
         first_greater_or_equal/1,
         offset/2]).

-include("../include/fdb.hrl").

last_less_than(K) -> ?FDB_KEYSEL_LAST_LESS_THAN(K).
last_less_or_equal(K) -> ?FDB_KEYSEL_LAST_LESS_OR_EQUAL(K).
first_greater_than(K) -> ?FDB_KEYSEL_FIRST_GREATER_THAN(K).
first_greater_or_equal(K) -> ?FDB_KEYSEL_FIRST_GREATER_OR_EQUAL(K).

offset(K=#keysel{offset=N}, X) -> K#keysel{offset=N+X}.
