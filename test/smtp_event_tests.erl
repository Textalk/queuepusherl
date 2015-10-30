-module(smtp_event_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MAIL_TEST_DATA, #{
          <<"type">> => <<"smtp">>,
          <<"data">> => #{
              <<"mail">> => #{
                  <<"from">> => <<"Alice <alice@example.com>">>,
                  <<"to">> => [<<"Bob <bob@example.com>">>],
                  <<"bcc">> => [<<"Cesar <cesar@example.com>">>],
                  <<"extra-headers">> => #{
                      <<"Subject">> => <<"This is an e-mail">>
                     },
                  <<"body">> => <<"Body of e-mail">>
                 },
              <<"smtp">> => #{
                  <<"relay">> => <<"dummyrelay">>,
                  <<"port">> => 2500,
                  <<"username">> => <<"alice">>,
                  <<"password">> => <<"alice secret password">>
                 },
              <<"error">> => #{
                  <<"to">> => <<"admin@example.com">>,
                  <<"subject">> => <<"Subject line of error e-mail">>,
                  <<"body">> => <<"Body of error e-mail">>
                 }
             }
         }).

parse_mail_test() ->
    TestData = jiffy:encode(?MAIL_TEST_DATA),
    {ok,
     {smtp, {smtp_event, Mail, _SMTP, Error}}
    } = qpusherl_event:parse(TestData, [{error_from, <<"<a@b.c>">>},
                                        {error_smtp, [{relay, <<>>},
                                                      {port, 25},
                                                      {username, <<>>},
                                                      {password, <<>>}]}]),
    ?assertMatch({mail, <<"<alice@example.com>">>,
                  [<<"<bob@example.com>">>,
                   <<"<cesar@example.com>">>],
                  _MailBody}, Mail),
    ?assertMatch({mailerror,
                  <<"admin@example.com">>,
                  <<"<a@b.c>">>,
                  <<"Subject line of error e-mail">>,
                  <<"Body of error e-mail">>,
                  _MailBody}, Error),
    ok.
