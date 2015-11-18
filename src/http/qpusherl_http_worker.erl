-module(qpusherl_http_worker).

-export([process_event/1]).
-export([fail_event/2]).

-spec process_event(qpusherl_http_event:http_event()) -> 'ok' | {'error', atom(), binary()}.
process_event(Event) ->
    #{method := Method,
      headers := Headers,
      content_type := ContentType,
      require_success := RequireSuccess,
      url := Url,
      data := Data} = qpusherl_http_event:get_request(Event),
    lager:info("Process HTTP event (~p): ~p ~s", [self(), Method, Url]),
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
        %% {ok, saved_to_file} ->
        %%     {ok, #{<<"Message">> => <<"Saved to file">>}};
        {ok, Result} ->
            case Result of
                {{_HTTP, StatusCode, StatusText}, _Headers, Body}
                  when StatusCode >= 200, StatusCode < 300 ->
                    CapBody = ellipsis_string(unicode:characters_to_binary(Body), 28),
                    lager:notice("Got success response (~p): ~s -> ~s", [self(), StatusText, CapBody]),
                    %lager:debug("Whole response: ~p", [Result]),
                    {ok, #{<<"StatusCode">> => StatusCode,
                           <<"StatusText">> => StatusText,
                           <<"Body">> => Body}};
                {{_HTTP, StatusCode, StatusText}, _Headers, Body} ->
                    lager:warning("Got failed response ~p (~p) (~p)",
                                  [StatusText, StatusCode, self()]),
                    if
                        RequireSuccess -> {error, {failed_response, StatusText}};
                        true -> {ok, #{<<"StatusCode">> => StatusCode,
                                       <<"StatusText">> => StatusText,
                                       <<"Body">> => Body}}
                    end
            end;
        {error, Reason} ->
            lager:info("Could not perform HTTP request (~p): ~p", [self(), Reason]),
            {error, {connection_failed, Reason}}
    end.

fail_event(_Event, _Errors) ->
    lager:notice("HTTP event failed (~p)", [self()]),
    ok.

ellipsis_string(String, Length) ->
    case (size(String) + 3) > Length of
        true ->
            ShortBody = string:substr(unicode:characters_to_list(String), 1, Length),
            <<(unicode:characters_to_binary(ShortBody))/binary, "...">>;
        false ->
            String
    end.

