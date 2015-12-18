-module(qpusherl_smtp_worker).

-export([process_event/1]).
-export([fail_event/2]).

process_event(Event) ->
    lager:notice("Process SMTP event!"),
    send_mail(Event).

fail_event(Event, Errors) ->
    send_error_mail(Event, Errors).

send_mail(Event) ->
    Mail = qpusherl_smtp_event:get_mail(Event),
    Smtps = qpusherl_smtp_event:get_smtp_options(Event),
    %lager:debug("send_mail(Event = ~p)~nMail: ~p~nSmtp: ~p~n", [Event, Mail,
                                                                           %Smtp]),
    %{A, B, C} = erlang:now(),
    %N = (A + B + C) rem 3,
    %case N of
        %N when N =< 0 -> exit({no_reason, "Just don't feel like it!"});
        %N -> timer:send_after(timer:seconds(N), timeout),
             %receive timeout -> ok end,
             %ok
    %end.
    send_mail_(Mail, Smtps).

send_mail_(Mail, [SMTP | Rest]) ->
    Result0 = case gen_smtp_client:send_blocking(Mail, SMTP) of
                 Receipt when is_binary(Receipt) ->
                     {ok, #{<<"Receipt">> => Receipt,
                            <<"Message">> => <<"SMTP request finished">>}};
                 {error, Type, Message} ->
                     {error, {Type, Message}};
                 {error, Reason0} ->
                     {error, {unknown_error, Reason0}}
             end,
    case Result0 of
        {ok, _} ->
            Result0;
        {error, Reason1} ->
            case Rest of
                [] ->
                    {error, [{SMTP, Reason1}]};
                _ ->
                    case send_mail_(Mail, Rest) of
                        {ok, _} = Result1 -> Result1;
                        {error, Errors} -> {error, [{SMTP, Reason1} | Errors]}
                    end
            end
    end.

send_error_mail(Event, Errors) ->
    ErrorMail = qpusherl_smtp_event:get_error_mail(Event, Errors),
    ErrorSmtp = qpusherl_smtp_event:get_error_smtp(Event),
    if ErrorMail == undefined orelse ErrorSmtp == undefined -> ok;
       true -> lager:debug("send_error_mail(#state{event = ~p})~n"
                           "ErrorMail: ~p~n"
                           "ErrorSmtp: ~p", [Event, ErrorMail, ErrorSmtp]),
            case gen_smtp_client:send_blocking(ErrorMail, ErrorSmtp) of
                Receipt when is_binary(Receipt) ->
                    ok;
                {error, Type, Message} ->
                    lager:error("Failed to send error mail: ~p ~p", [Type, Message]);
                {error, Reason} ->
                    lager:error("Failed to send error mail: ~p", [Reason])
            end
    end.
