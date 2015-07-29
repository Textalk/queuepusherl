-module(qpusherl_event).

-export([parse/1]).

-define(EVENT_TYPES, #{
          <<"smtp">> => qpusherl_smtp_event,
          <<"http">> => qpusherl_http_event
         }).

-opaque event() :: qpusherl_smtp_event:smtp_event() | qpusherl_http_event:http_event().
-export_type([event/0]).

-spec parse(binary()) -> {ok, {atom(), event()}} | {error, term()}.
parse(BinaryEvent) ->
    try
        EventMap = jiffy:decode(BinaryEvent, [return_maps]),
        EventType = maps:get(<<"type">>, EventMap),
        EventData = maps:get(<<"data">>, EventMap),
        case maps:find(EventType, ?EVENT_TYPES) of
            {ok, Module} ->
                AType = list_to_atom(unicode:characters_to_list(EventType)),
                case Module:parse(EventData) of
                    {ok, Event} -> {ok, {AType, Event}};
                    {error, Reason0} -> {error, failed_parse, Reason0}
                end;
            Other ->
                lager:debug("No event type for ~s: ~p~nEvent: ~p", [EventType, Other, BinaryEvent]),
                {error, no_parse_module, <<"Could not parse event type, ", EventType/binary>>}
        end
    catch
        error:Reason1 ->
            {Explaination, _Trace} = extend_error(Reason1, erlang:get_stacktrace()),
            {error, Reason1, Explaination};
        throw:Reason1 ->
            {Explaination, _Trace} = extend_error(Reason1, erlang:get_stacktrace()),
            {error, Reason1, Explaination}
    end.

extend_error(function_clause = Reason, [{Mod, Fun, Args, [{file, File}, {line, Line}]}|Tail]) ->
    Args1 = lists:map(fun (A) -> io_lib:format("~p", [A]) end, Args),
    {list_to_binary(io_lib:format("~p :: ~p:~p(~s) @~s:~p",
                                  [Reason, Mod, Fun,
                                   string:join(Args1, ", "),
                                   File, Line])),
     Tail};
extend_error(bad_key, [{maps, get, [Key, Map], []}
                       |[{Mod, Fun, Arity, [{file, File}, {line, Line}]}
                         |Tail]]) ->
    {list_to_binary(io_lib:format("bad_key ~p in ~p at ~p:~p/~p @~s:~p",
                                  [Key, Map, Mod, Fun, Arity, File, Line])), Tail};
extend_error(_Reason, Trace) ->
    {<<>>, Trace}.
