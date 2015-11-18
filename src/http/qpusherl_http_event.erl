-module(qpusherl_http_event).

-export([parse/2]).

-export([get_request/1]).

-type http_req() :: map().

-record(http_event, {request :: http_req()}).
-opaque http_event() :: #http_event{}.
-export_type([http_event/0]).

-spec parse(map(), [{atom(), term()}]) -> {'ok', http_event()} | {'error', Reason :: binary()}.
parse(#{<<"request">> := Request}, _Config) ->
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
                 <<"content-type">> => undefined,
                 <<"require-success">> => false,
                 <<"query">> => #{},
                 <<"data">> => #{},
                 <<"url">> => undefined},
    #{<<"method">> := InMethod,
      <<"extra-headers">> := InHeaders,
      <<"content-type">> := InContentType,
      <<"require-success">> := RequireSuccess,
      <<"query">> := InQuery,
      <<"data">> := InData,
      <<"url">> := InURL} = maps:merge(Defaults, EventData),
    Method = erlang:list_to_existing_atom(string:to_lower(unicode:characters_to_list(InMethod))),
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
                            _ -> integer_to_binary(Port)
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
    Headers = InHeaders,
    case encode_data(InContentType, InData) of
        {ok, {ContentType, Data}} ->
            {ok, #{method => Method,
                   headers => Headers,
                   content_type => ContentType,
                   require_success => RequireSuccess,
                   url => format_url(URLparts),
                   data => Data}};
        Error -> Error
    end.

url_encode(Map) when is_map(Map) ->
    url_encode(maps:to_list(Map));
url_encode(List) ->
    case lists:foldr(
           fun (_, {error, Reason}) ->
                   {error, Reason};
               ({K, V}, Acc) when is_integer(V) ->
                   [{K, integer_to_binary(V)} | Acc];
               ({K, V}, Acc) when is_binary(V) ->
                   [{K, V} | Acc];
               (_, _) ->
                   {error, {invalid_message, <<"Data can only contain integer and binaries">>}}
           end,
           [],
           List) of
        {error, _} = Error -> Error;
        List1 -> {ok, cow_qs:qs(List1)}
    end.

encode_data(ContentType, Data) when is_map(Data) ->
    case ContentType of
        <<"application/json">> ->
            {ok, {ContentType, jiffy:encode(Data)}};
        _ when ContentType == undefined; ContentType == <<"application/x-www-form-urlencoded">> ->
            case url_encode(Data) of
                {ok, Data0} -> {ok, {<<"application/x-www-form-urlencoded">>, Data0}};
                Error -> Error
            end;
        _ ->
            {error, {invalid_content_type, ContentType}}
    end;
encode_data(undefined, Data) when is_binary(Data) ->
    {ok, {<<"text/plain">>, Data}};
encode_data(ContentType, Data) when is_binary(Data) ->
    {ok, {ContentType, Data}}.

-spec get_request(http_event()) -> http_req().
get_request(#http_event{request = Req}) ->
    Req.

format_url({Schema, User, Host, Port, Path, QueryList, Fragment}) ->
    Query = cow_qs:qs(QueryList),
    iolist_to_binary([Schema, <<"://">>] ++
                     [<<User/binary, "@">> || User /= <<>>] ++
                     [Host] ++
                     [<<":", Port/binary>> || Port /= <<>>] ++
                     [Path] ++
                     [<<"?", Query/binary>> || Query /= <<>>] ++
                     [<<"#", Fragment/binary>> || Fragment /= <<>>]).
