-module(qpusherl_http_worker).

-export([process_event/1]).
-export([fail_event/1]).

process_event({Event, _Errors}) ->
    lager:info("Process HTTP event!", []),
    #{method := Method,
      headers := Headers,
      content_type := ContentType,
      url := Url,
      data := Data} = qpusherl_http_event:get_request(Event),
    lager:notice("Do request: ~p ~p ~p", [Method, Url, Data]),
    SUrl = unicode:characters_to_list(Url),
    LHeaders = maps:to_list(Headers),
    SContentType = unicode:characters_to_list(ContentType),
    ReqData = case Method of 
                  _ when Method == get; Method == delete; Method == head ;
                         Method == options ; Method == trace ->
                      {SUrl, LHeaders};
                  _ ->
                      {SUrl, LHeaders, SContentType, Data}
              end,
    case httpc:request(Method, ReqData, [], []) of
        {ok, saved_to_file} ->
            ok;
        {ok, Result} ->
            case Result of 
                {{_HTTP, 200, _StatusText}, _Headers, _Body} ->
                    lager:notice("Got success response: ~p", [Result]);
                {{_HTTP, StatusCode, StatusText}, _Headers, _Body} ->
                    lager:warning("Got failed response ~p (~p)", [StatusText, StatusCode])
            end,
            ok;
        {error, Reason} ->
            lager:error("Could not perform request: ~p", [Reason]),
            {error, connection_failed, Reason}
    end.

fail_event({_Event, _Errors}) ->
    lager:notice("HTTP request failed", []),
    ok.
