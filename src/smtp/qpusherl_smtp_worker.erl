-module(qpusherl_smtp_worker).
%-behaviour(gen_server).

-export([process_event/1]).
-export([fail_event/2]).

process_event(Event) ->
    lager:notice("Process SMTP event!"),
    send_mail(Event).

fail_event(Event, Errors) ->
    send_error_mail(Event, Errors).

send_mail(Event) ->
    Mail = qpusherl_smtp_event:get_mail(Event),
    Smtp = qpusherl_smtp_event:get_smtp_options(Event),
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
    case gen_smtp_client:send_blocking(Mail, Smtp) of
        Receipt when is_binary(Receipt) ->
            ok;
        {error, Type, Message} ->
            {error, Type, Message};
        {error, Reason} ->
            {error, unknown_error, Reason}
    end.

send_error_mail(Event, Errors) ->
    ErrorMail = qpusherl_smtp_event:get_error_mail(Event, Errors),
    ErrorSmtp = qpusherl_smtp_event:get_error_smtp(Event),
    lager:debug("send_error_mail(#state{event = ~p})~nErrorMail: ~p~nErrorSmtp: ~p~n", [Event,
                                                                                        ErrorMail,
                                                                                        ErrorSmtp]),
    case gen_smtp_client:send_blocking(ErrorMail, ErrorSmtp) of
        Receipt when is_binary(Receipt) ->
            ok;
        {error, Type, Message} ->
            lager:error("Failed to send error mail: ~p ~p", [Type, Message]);
        {error, Reason} ->
            lager:error("Failed to send error mail: ~p", [Reason])
    end.
