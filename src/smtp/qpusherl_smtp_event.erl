-module(qpusherl_smtp_event).

-export([parse/1]).
-export([get_mail/1]).
-export([get_error_mail/2]).
-export([get_smtp_options/1]).

-record(mail, {from :: binary(),
               to :: [binary()],
               body :: binary()}).
-type mail() :: #mail{}.

-record(smtp, {relay :: binary(),
               port :: integer(),
               username :: binary(),
               password :: binary()}).
-type smtp() :: #smtp{}.

-record(mailerror, {to :: binary(),
                    subject :: binary(),
                    body :: binary()}).
-type mailerror() :: #mailerror{}.

-type extern_mail() :: {From :: binary(),
                        To :: [binary()],
                        Body :: binary()}.

-record(smtp_event, {mail :: mail(),
                     smtp :: smtp(),
                     error :: mailerror()}).
-opaque smtp_event() :: #smtp_event{}.
-export_type([smtp_event/0]).

-spec parse(map()) -> {ok, smtp_event()} | {error, Reason :: binary()}.
parse(#{<<"mail">> := MailInfo,
        <<"smtp">> := SmtpInfo,
        <<"error">> := MailErrorInfo}) ->
    Mail = build_mail(MailInfo),
    Smtp = build_smtp(SmtpInfo),
    Error = build_error(MailErrorInfo),
    {ok, #smtp_event{mail = Mail, smtp = Smtp, error = Error}}.

-spec build_mail(map()) -> mail().
build_mail(MailInfo) ->
    From = maps:get(<<"from">>, MailInfo),
    To = maps:get(<<"to">>, MailInfo, []),
    Cc = maps:get(<<"cc">>, MailInfo, []),
    Bcc = maps:get(<<"bcc">>, MailInfo, []),
    HeadersMap = maps:get(<<"extra-headers">>, MailInfo, #{}),
    Body = maps:get(<<"body">>, MailInfo),
    Headers = maps:to_list(HeadersMap),
    true = is_binary(From),
    true = lists:all(fun is_binary/1, To ++ Cc ++ Bcc),
    true = lists:all(fun ({_Key, Value}) ->is_binary(Value) end, Headers),
    true = is_binary(Body),
    Headers1 = [{<<"From">>, From}] ++
               [{<<"To">>, join(To)} || To /= []] ++
               [{<<"Cc">>, join(Cc)} || Cc /= []] ++
               Headers,
    Headers2 = [{to_header_case(Header), Value} || {Header, Value} <- Headers1],
    Headers3 = case proplists:is_defined(<<"Date">>, Headers2) of
                   false ->
                       Date = unicode:characters_to_binary(smtp_util:rfc5322_timestamp()),
                       Headers2 ++ [{<<"Date">>, Date}];
                   true ->
                       Headers2
               end,
    MailFrom = extract_email_address(From),
    RcptTo = lists:map(fun extract_email_address/1, To ++ Cc ++ Bcc),
    Mail = mimemail:encode({<<"text">>, <<"plain">>, Headers3, [], Body}),

    #mail{from = MailFrom, to = RcptTo, body = Mail}.

-spec build_smtp(map()) -> smtp().
build_smtp(SmtpInfo) ->
    Relay = maps:get(<<"relay">>, SmtpInfo),
    Port = maps:get(<<"port">>, SmtpInfo),
    Username = maps:get(<<"username">>, SmtpInfo),
    Password = maps:get(<<"password">>, SmtpInfo),
    true = is_binary(Relay) or (Relay == undefined),
    true = is_integer(Port) or (Port == undefined),
    true = is_binary(Username) or (Username == undefined),
    true = is_binary(Password) or (Password == undefined),
    #smtp{relay = Relay, port = Port, username = Username, password = Password}.

-spec build_error(map()) -> mailerror().
build_error(ErrorInfo) ->
    To = maps:get(<<"to">>, ErrorInfo),
    Subject = maps:get(<<"subject">>, ErrorInfo),
    Body = maps:get(<<"body">>, ErrorInfo),
    true = is_binary(To),
    true = is_binary(Subject),
    true = is_binary(Body),
    #mailerror{to = To, subject = Subject, body = Body}.

-spec get_error_mail(smtp_event(), term()) -> extern_mail().
get_error_mail(#smtp_event{mail = #mail{body = OrigMail},
                           error = #mailerror{to = To,
                                              subject = Subject,
                                              body = Body}},
              Errors) ->
    {ok, ErrorFrom} = application:get_env(queuepusherl, error_from),
    MessagePart = {<<"text">>, <<"plain">>, [], [], Body},
    %ErrorsPart = {<<"text">>, <<"plain">>, [], [], join(Errors)},
    ErrorsPart = {<<"text">>, <<"plain">>, [], [],
                  unicode:characters_to_binary(io_lib:format("~p", [Errors]))},

    Attachement = {<<"message">>, <<"rfc822">>, [],
                   [{<<"content-type-params">>, [{<<"name">>, <<"Mail">>}]},
                    {<<"disposition">>, <<"attachment">>},
                    {<<"disposition-params">>, [{<<"filename">>, <<"Mail.eml">>}]}],
                   OrigMail},

    ErrorMail = mimemail:encode({<<"multipart">>, <<"mixed">>,
                                 [{<<"From">>, ErrorFrom},
                                  {<<"To">>, To},
                                  {<<"Subject">>, Subject}],
                                 [],
                                 [MessagePart, ErrorsPart, Attachement]}),
    {extract_email_address(ErrorFrom), [extract_email_address(To)], ErrorMail}.

-spec get_mail(smtp_event()) -> extern_mail().
get_mail(#smtp_event{mail = #mail{from = From,
                                  to = To,
                                  body = Body}}) ->
    {From, To, Body}.

%% @doc Returns a proplist that can be used as the 2nd argument to
%% gen_smtp_client:send/2,3 and gen_smtp_client:send_blocking/2.
-spec get_smtp_options(smtp_event()) -> [{atom(), term()}].
get_smtp_options(#smtp_event{smtp = #smtp{relay = Relay,
                                          port = Port,
                                          username = User,
                                          password = Password}}) ->
    [{relay, Relay} || Relay /= undefined] ++
    [{port, Port}  || Port /= undefined] ++
    [{username, User} || User /= undefined] ++
    [{password, Password} || Password /= undefined].

%% ------------------------------------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------------------------------------

%% @doc Returns a binary on the form `<<"<email@example.com>">>'.
-spec extract_email_address(binary()) -> binary().
extract_email_address(Bin) ->
    case re:run(Bin, <<"<.*@.*>$">>, [{capture, all, binary}]) of
        {match, [Email]} ->
            Email;
        nomatch ->
            case re:run(Bin, <<"^\\S+@\\S+$">>, [{capture, none}]) of
                match -> <<"<", Bin/binary, ">">>;
                nomatch -> throw({invalid_email, Bin})
            end
    end.

%% @doc Converts a header field name to "Header-Case", i.e. uppercase first char in each
%% dash-separated part.
-spec to_header_case(binary()) -> binary().
to_header_case(Binary) ->
    String = string:to_lower(unicode:characters_to_list(Binary)),
    Tokens = string:tokens(String, "-"),
    HeaderCaseTokens = [[string:to_upper(First) | Rest] || [First|Rest] <- Tokens],
    HeaderCase = string:join(HeaderCaseTokens, "-"),
    unicode:characters_to_binary(HeaderCase).

%% @doc Creates a comma + space separated list
-spec join([binary()]) -> binary().
join(Xs) -> join(Xs, <<>>).

join([], _) -> <<>>;
join([X], Acc) -> <<Acc/binary, X/binary>>;
join([X|Xs], Acc) -> join(Xs, <<Acc/binary, X/binary, ", ">>).

