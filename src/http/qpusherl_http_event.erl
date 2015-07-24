-module(qpusherl_http_event).

-export([parse/1]).

-export([get_request/1]).

-type http_req() :: map().

-record(http_event, {request :: http_req()}).
-opaque http_event() :: #http_event{}.
-export_type([http_event/0]).

-spec parse(map()) -> {'ok', http_event()} | {'error', Reason :: binary()}.
parse(#{<<"request">> := Request}) ->
    case build_request(Request) of
        {ok, HttpReq} ->
            {ok, #http_event{request = HttpReq}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec build_request(map()) -> {'ok', http_req()} | {'error', term()}.
build_request(EventData) ->
    Defaults = #{<<"method">> => <<"GET">>,
                <<"extra-headers">> => #{},
                <<"content-type">> => <<"text/plain">>,
                <<"query">> => #{},
                <<"data">> => #{},
                <<"url">> => undefined},
    #{<<"method">> := InMethod,
      <<"extra-headers">> := InHeaders,
      <<"content-type">> := InContentType,
      <<"query">> := InQuery,
      <<"data">> := InData,
      <<"url">> := InURL} = maps:merge(Defaults, EventData),
    Method = erlang:list_to_atom(string:to_lower(unicode:characters_to_list(InMethod))),
    URLparts = case http_uri:parse(unicode:characters_to_list(InURL), [{fragment, true}]) of
                   {ok, {Schema, UserInfo, Host, Port, Path, UrlQuery, UrlFragment}} ->
                       ExpectedPort = case Schema of
                                          http -> 80;
                                          https -> 443
                                      end,
                       {atom_to_binary(Schema, utf8),
                        unicode:characters_to_binary(UserInfo),
                        unicode:characters_to_binary(Host),
                        case Port of
                            ExpectedPort -> <<>>;
                            _ -> unicode:characters_to_binary(io_lib:format("~p", [Port]))
                        end,
                        unicode:characters_to_binary(Path),
                        case UrlQuery of
                            [$?|Query] ->
                                cow_qs:parse_qs(unicode:characters_to_binary(Query));
                            _ ->
                                []
                        end ++ maps:to_list(InQuery),
                        case UrlFragment of
                            [$#|Fragment] ->
                                unicode:characters_to_binary(Fragment);
                            _ ->
                                <<>>
                        end}
               end,
    Data = case InData of
               _ when is_map(InData) -> cow_qs:qs(maps:to_list(InData));
               _ -> InData
           end,
    Headers = InHeaders,
    ContentType = InContentType,
    {ok, #{method => Method,
           headers => Headers,
           content_type => ContentType,
           url => format_url(URLparts),
           data => case Data of
                       #{} -> cow_qs:qs(maps:to_list(Data));
                       _ when is_binary(Data) -> Data
                   end}}.

-spec get_request(http_event()) -> http_req().
get_request(#http_event{request = Req}) ->
    Req.

format_url({Schema, User, Host, Port, Path, QueryList, Fragment}) ->
    Query = cow_qs:qs(QueryList),
    binary_join([Schema, <<"://">>] ++
                [<<User/binary, "@">> || User /= <<>>] ++
                [Host] ++
                [<<":", Port/binary>> || Port /= <<>>] ++
                [Path] ++
                [<<"?", Query/binary>> || Query /= <<>>] ++
                [<<"#", Fragment/binary>> || Fragment /= <<>>]).

-spec binary_join([binary()]) -> binary().
binary_join([]) ->
    <<>>;
binary_join([Part|Rest]) ->
    <<Part/binary, (binary_join(Rest))/binary>>.
