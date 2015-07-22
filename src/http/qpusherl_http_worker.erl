-module(qpusherl_http_worker).

-export([process_event/1]).
-export([fail_event/1]).

process_event({Event, _Errors}) ->
    lager:info("Process HTTP event! ~p", [Event]),
    #{method := Method,
      url := Url,
      data := Data} = qpusherl_http_event:get_request(Event),
    lager:notice("Do request: ~p ~p ~p", [Method, Url, Data]),
    ok.

fail_event({_Event, _Errors}) ->
    lager:notice("HTTP request failed", []),
    ok.
