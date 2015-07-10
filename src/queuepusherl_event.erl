-module(queuepusherl_event).

-export([parse/1]).

-include("queuepusherl_events.hrl").

-spec parse(binary()) -> {ok, event()} | {error, term()}.
parse(BinaryEvent) ->
    try
        EventMap = jiffy:decode(BinaryEvent, [return_maps]),
        case {maps:get(<<"type">>, EventMap),
              maps:get(<<"data">>, EventMap)} of
            {<<"smtp">>, Data} ->
                {ok, SmtpEvent} = queuepusherl_smtp_event:parse(Data),
                {smtp, SmtpEvent}
        end
    of
        Event -> {ok, Event}
    catch
        error:Reason ->
            {Explaination, _Trace} = extend_error(Reason, erlang:get_stacktrace()),
            {error, Reason, Explaination};
        throw:Reason ->
            {Explaination, _Trace} = extend_error(Reason, erlang:get_stacktrace()),
            {error, Reason, Explaination}
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
