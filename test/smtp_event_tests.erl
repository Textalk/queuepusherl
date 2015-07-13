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
    {ok, {smtp, Mail, _SMTP, Error}} = qpusherl_event:parse(TestData),
    ?assertMatch({<<"<alice@example.com>">>,
                  [<<"<bob@example.com>">>,
                   <<"<cesar@example.com>">>],
                 _MailBody}, Mail),
    ?assertMatch({mailerror,
                  <<"admin@example.com">>,
                  <<"Subject line of error e-mail">>,
                 _MailBody}, Error),
    ok.
