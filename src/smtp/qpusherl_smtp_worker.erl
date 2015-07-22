-module(qpusherl_smtp_worker).
%-behaviour(gen_server).

-export([process_event/1]).
-export([fail_event/1]).

process_event({Event, _Errors}) ->
    lager:notice("Process SMTP event!"),
    send_mail(Event),
    ok.

fail_event({_Event, _Errors}) ->
    ok.

send_mail(Event) ->
    Mail = qpusherl_smtp_event:get_mail(Event),
    Smtp = qpusherl_smtp_event:get_smtp_options(Event),
    lager:debug("send_mail(Event = ~p)~nMail: ~p~nSmtp: ~p~n", [Event, Mail,
                                                                           Smtp]),
    {A, B, C} = erlang:now(),
    N = (A + B + C) rem 3,
    case N of
        N when N =< 0 -> exit({no_reason, "Just don't feel like it!"});
        N -> timer:send_after(timer:seconds(N), timeout),
             receive timeout -> ok end,
             ok
    end.
    %%case gen_smtp_client:send_blocking(Mail, Smtp) of
        %%Receipt when is_binary(Receipt) ->
            %%{done, State};
        %%{error, no_more_hosts, {permanent_failure, _Host, _Message}} ->
            %%send_error_mail(State),
            %%{done, State};
        %%{error, Type, Message} ->
            %%Event1 = qpusherl_smtp_event:add_error(Event, make_mail_error(Type, Message)),
            %%{retry, State#state{event = Event1}};
        %%{error, Reason} ->
            %%Event1 = qpusherl_smtp_event:add_error(Event, make_mail_error(unknown_error, Reason)),
            %%{retry, State#state{event = Event1}}
    %%end.

%%send_error_mail(#state{event = Event}) ->
    %%{ok, ErrorSmtp} = application:get_env(queuepusherl, error_smtp),
    %%ErrorMail = qpusherl_smtp_event:get_error_mail(Event),
    %%lager:debug("send_error_mail(#state{event = ~p})~nErrorMail: ~p~nErrorSmtp: ~p~n", [Event,
                                                                                      %%ErrorMail,
                                                                                      %%ErrorSmtp]).
    %%case gen_smtp_client:send_blocking(ErrorMail, ErrorSmtp) of
        %%Receipt when is_binary(Receipt) ->
            %%ok;
        %%{error, Type, Message} ->
            %%error_logger:error_msg("Failed to send error mail: ~p ~p", [Type, Message]);
        %%{error, Reason} ->
            %%error_logger:error_msg("Failed to send error mail: ~p", [Reason])
    %%end.

%%make_mail_error(Name, Msg) ->
    %%BinMsg = case is_binary(Msg) of
                 %%true -> Msg;
                 %%false -> list_to_binary(io_lib:format("~p", [Msg]))
             %%end,
    %%BinName = atom_to_binary(Name, utf8),
    %%<<"{ ", BinName/binary, ": ", BinMsg/binary, " }">>.
