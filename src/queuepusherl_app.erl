-module(queuepusherl_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

start(_Type, _Args) ->
    lager:info("Queuepusherl started!"),
    qpusherl_sup:start_link().

stop(_State) ->
    lager:warning("Queuepusherl stopped!"),
    ok.
