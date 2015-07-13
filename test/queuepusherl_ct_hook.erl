-module(qpusherl_ct_hook).

-export([id/1]).
-export([init/2]).
-export([terminate/1]).

-export([on_tc_fail/3]).

-record(state, {}).

id(Opts) ->
    proplists:get_value(filename, Opts, "/tmp/qpusherl_ct_hooks.log").

init(_Id, _Opts) ->
    {ok, #state{}}.

terminate(_State) ->
    ok.

on_tc_fail(TC, {failed, {ErrorClass, Error}}, State) ->
    ct:pal("~p uncaught exception ~p:~n~p", [TC, ErrorClass, Error]),
    State;
on_tc_fail(TC, Reason, State) ->
    ct:pal("~p failed:~n~p", [TC, Reason]),
    State.
