-module(qpusherl_smtp_event).

-export([parse/2]).
-export([get_mail/1]).
-export([get_error_mail/2]).
-export([get_error_smtp/1]).
-export([get_smtp_options/1]).

-record(parthead, {
          content_type = {<<"text">>, <<"plain">>} :: {binary(), binary()},
          content_type_params = #{}                :: maps:map(),
          disposition = <<"inline">>               :: binary(),
          disposition_params = #{}                 :: maps:map(),
          encoding = undefined                     :: 'undefined' | binary()
         }).
-record(part, {
          headers = #parthead{} :: #parthead{},
          body = <<>>           :: #part{} | binary()
         }).
-type mail() :: {'mail', From :: binary(), To :: [binary()], Body :: binary()}.

-record(smtp, {
          relay    :: binary(),
          port     :: integer(),
          username :: binary(),
          password :: binary()}).
-type smtp() :: #smtp{}.

-record(mailerror, {
          to      :: binary(),
          from    :: binary(),
          subject :: binary(),
          body    :: binary(),
          smtp    :: term()}).
-type mailerror() :: #mailerror{}.

-type extern_mail() :: {
        From :: binary(),
        To   :: [binary()],
        Body :: binary()}.

-record(smtp_event, {
          mail  :: mail(),
          smtps :: [smtp()],
          error :: mailerror() | 'undefined'}).
-opaque smtp_event() :: #smtp_event{}.
-export_type([smtp_event/0]).

-spec parse(map(), [{atom(), term()}]) -> {ok, smtp_event()} | {error, Reason :: binary()}.
parse(EventInfo, State) ->
    MailInfo = maps:get(<<"mail">>, EventInfo),
    SmtpInfo = maps:get(<<"smtp">>, EventInfo),
    MailErrorInfo = maps:get(<<"error">>, EventInfo, undefined),
    Mail = parse_mail(MailInfo),
    Smtps = case is_list(SmtpInfo) of
                true -> [parse_smtp(Info) || Info <- SmtpInfo];
                false -> [parse_smtp(SmtpInfo)]
            end,
    Error = case MailErrorInfo of
                undefined -> undefined;
                _ -> 
                    ErrorFrom = qpusherl_event:get_config(error_from, State),
                    ErrorSmtp = qpusherl_event:get_config(error_smtp, State),
                    parse_error(MailErrorInfo#{<<"from">> => ErrorFrom, <<"smtp">> => ErrorSmtp})
            end,
    {ok, #smtp_event{mail = Mail,
                     smtps = Smtps,
                     error = Error}}.

parse_header_with_params(FieldValue) ->
    case binary:split(FieldValue, <<";">>) of
        [HeaderValue] -> {HeaderValue, []};
        [HeaderValue, Parameters] ->
            RawParams0 = re:split(Parameters, <<"[[:space:]]*(?=[^\\\\]);[[:space:]]*">>),
            RawParams1 = [trim_binary(RawParam) || RawParam <- RawParams0],
            Params = lists:map(
                       fun (M) ->
                               case re:split(M, <<"[[:space:]]*=[[:space:]]*">>, [{parts, 2}]) of
                                   [Key] -> {Key, true};
                                   [Key, Value] -> {Key, Value}
                               end
                       end,
                       RawParams1),
            {HeaderValue, Params}
    end.

ensure_text_encoding(Headers = #parthead{content_type = {<<"text">>, _},
                                         content_type_params = Params}) ->
    case proplists:get_value(<<"charset">>, Params, undefined) of
        undefined -> Headers#parthead{
                       content_type_params = lists:keystore(<<"charset">>, 1, Params,
                                                            {<<"charset">>, <<"utf-8">>})};
        _ -> Headers
    end;
ensure_text_encoding(Headers) ->
    Headers.

parse_mail_part_headers(Headers) ->
    Headers0 = maps:fold(
                 fun (<<"content-type">>, Value, Head) ->
                         {CT, Params} = parse_header_with_params(Value),
                         [Major, Minor] = binary:split(CT, <<"/">>),
                         CT1 = {Major, Minor},
                         Head#parthead{content_type = CT1,
                                       content_type_params = Params};
                     (<<"content-disposition">>, Value, Head = #parthead{disposition_params = Params0}) ->
                         {CD, Params} = parse_header_with_params(Value),
                         Head#parthead{disposition = CD,
                                       disposition_params = Params0 ++ Params};
                     (<<"content-filename">>, Value, Head = #parthead{disposition_params = Params0}) ->
                         Params1 = lists:keystore(<<"filename">>, 1, Params0,
                                                  {<<"filename">>, Value}),
                         Head#parthead{disposition = <<"attachment">>,
                                       disposition_params = Params1};
                     (<<"content-encoding">>, Value, Head) ->
                         Head#parthead{encoding = Value}
                 end,
                 #parthead{content_type = {<<"text">>, <<"plain">>},
                           content_type_params = [],
                           disposition = <<"inline">>,
                           disposition_params = [],
                           encoding = undefined},
                 Headers),
    ensure_text_encoding(Headers0).

parse_mail_body(Body) when is_binary(Body) ->
    Body;
parse_mail_body(Parts) ->
    parse_mail_body_parts(Parts).

parse_mail_body_parts([]) ->
    [];
parse_mail_body_parts([Part | Parts]) ->
    Headers = parse_mail_part_headers(maps:get(<<"headers">>, Part, #{})),
    Body = case {Headers#parthead.encoding, maps:get(<<"body">>, Part)} of
               {_, Body0} when is_list(Body0) ->
                   parse_mail_body_parts(Body0);
               {<<"base64">>, Body0} when is_binary(Body0) ->
                   lager:info("Encode message ~s", [Body0]),
                   base64:decode(Body0); %% If we do not decode messages encoded in Base64 it will
                                         %% be double encoded.
               {_, Body0} -> Body0
           end,
    Body = parse_mail_body(maps:get(<<"body">>, Part)),
    [#part{headers = Headers, body = Body} | parse_mail_body_parts(Parts)].

construct_body(Body) when is_binary(Body) ->
    Body;
construct_body([]) ->
    [];
construct_body([#part{headers = #parthead{content_type = {CTMajor, CTMinor},
                                          content_type_params = CTParams,
                                          disposition = Disposition,
                                          disposition_params = DispositionParams,
                                          encoding = Encoding},
                      body = Body} | Parts]) ->
    Body0 = construct_body(Body),
    DispositionParams0 = lists:map(fun ({K, true}) -> K;
                                       ({K, V}) -> <<K/binary, $\=, V/binary>>
                                   end, DispositionParams),
    DispositionParams1 = lists:foldl(fun (Param, Rest) ->
                                             case Rest of
                                                 <<>> -> Param;
                                                 _ -> <<Param/binary, $\;, Rest/binary>>
                                             end
                                     end,
                                     <<>>,
                                     DispositionParams0),

    Disposition1 = case DispositionParams1 of
                       <<>> -> Disposition;
                       _ -> <<Disposition/binary, "; ", DispositionParams1/binary>>
                   end,
    Headers = case Encoding of
                  undefined -> [];
                  _ -> [{<<"Content-Transfer-Encoding">>, Encoding}]
              end,

    [{CTMajor, CTMinor, Headers,
      lists:flatten([[{<<"content-type-params">>, CTParams} || CTParams /= []],
                     [{<<"disposition">>, Disposition1} || Disposition1 /= <<"inline">>]]),
      Body0} | construct_body(Parts)].

-spec parse_mail(map()) -> mail().
parse_mail(MailInfo) ->
    From = maps:get(<<"from">>, MailInfo),
    To = maps:get(<<"to">>, MailInfo, []),
    Cc = maps:get(<<"cc">>, MailInfo, []),
    Bcc = maps:get(<<"bcc">>, MailInfo, []),
    Subject = maps:get(<<"subject">>, MailInfo, undefined),
    HeadersMap = maps:get(<<"extra-headers">>, MailInfo, #{}),
    ContentType = maps:get(<<"content-type">>, MailInfo, undefined),
    not maps:is_key(<<"Content-Type">>, HeadersMap) orelse throw({invalid, headers,
                                                                   <<"Content-Type">>}),
    Body = parse_mail_body(maps:get(<<"body">>, MailInfo)),
    Headers = maps:to_list(HeadersMap),
    true = is_binary(From),
    true = lists:all(fun is_binary/1, To ++ Cc ++ Bcc),
    true = lists:all(fun ({_Key, Value}) -> is_binary(Value) end, Headers),
    Headers1 = lists:flatten([[{<<"From">>, From}],
                              [{<<"To">>, join(To)} || To /= []],
                              [{<<"Cc">>, join(Cc)} || Cc /= []],
                              [{<<"Subject">>, Subject} || is_binary(Subject)],
                              Headers]),
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
    {CTMajor, CTMinor} = case ContentType of
                             undefined when is_binary(Body) ->
                                 {<<"text">>, <<"plain">>};
                             undefined ->
                                 {<<"multipart">>, <<"mixed">>};
                             _ when is_binary(ContentType) ->
                                 [A, B] = binary:split(ContentType, <<"/">>),
                                 {A, B}
                         end,
    Mail = mimemail:encode({CTMajor, CTMinor, Headers3, [], construct_body(Body)}),

    {mail, MailFrom, RcptTo, Mail}.

-spec parse_smtp(map()) -> smtp().
parse_smtp(SmtpInfo) ->
    Relay = maps:get(<<"relay">>, SmtpInfo),
    Port = maps:get(<<"port">>, SmtpInfo),
    Username = maps:get(<<"username">>, SmtpInfo),
    Password = maps:get(<<"password">>, SmtpInfo),
    true = is_binary(Relay) or (Relay == undefined),
    true = is_integer(Port) or (Port == undefined),
    true = is_binary(Username) or (Username == undefined),
    true = is_binary(Password) or (Password == undefined),
    #smtp{relay = Relay, port = Port, username = Username, password = Password}.

-spec parse_error(map()) -> mailerror().
parse_error(ErrorInfo) ->
    To = maps:get(<<"to">>, ErrorInfo),
    From = maps:get(<<"from">>, ErrorInfo),
    Subject = maps:get(<<"subject">>, ErrorInfo),
    Body = maps:get(<<"body">>, ErrorInfo),
    Smtp = maps:get(<<"smtp">>, ErrorInfo),
    true = is_binary(To),
    true = is_binary(From),
    true = is_binary(Subject),
    true = is_binary(Body),
    #mailerror{to = To, from = From, subject = Subject, body = Body, smtp = Smtp}.

get_error_smtp(#smtp_event{error = undefined}) ->
    undefined;
get_error_smtp(#smtp_event{error = #mailerror{smtp = Smtp}}) ->
    Smtp.

-spec get_error_mail(smtp_event(), term()) -> extern_mail().
get_error_mail(#smtp_event{error = undefined}, _Errors) ->
    undefined;
get_error_mail(#smtp_event{mail = {mail, _, _, OrigMail},
                           error = #mailerror{to = To,
                                              from = ErrorFrom,
                                              subject = Subject,
                                              body = Body}},
              Errors) ->
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
get_mail(#smtp_event{mail = {mail, From, To, Body}}) ->
    {From, To, Body}.

%% @doc Returns a proplist that can be used as the 2nd argument to
%% gen_smtp_client:send/2,3 and gen_smtp_client:send_blocking/2.
-spec get_smtp_options(smtp_event()) -> [{atom(), term()}].
get_smtp_options(#smtp_event{smtps = SMTPs}) ->
    lists:map(fun (#smtp{relay = Relay,
                         port = Port,
                         username = User,
                         password = Password}) ->
                      [{relay, Relay} || Relay /= undefined] ++
                      [{port, Port}  || Port /= undefined] ++
                      [{username, User} || User /= undefined] ++
                      [{password, Password} || Password /= undefined]
              end,
              SMTPs).

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

-spec trim_binary(binary()) -> binary().
trim_binary(<<" ", Rest/binary>>) ->
    trim_binary(Rest);
trim_binary(Done) ->
    Done.

