-module(smtp_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../deps/amqp_client/include/amqp_client.hrl").

-export([parse/1]).

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

-define(RAW_MAIL_EVENT, #{<<"mail">> => #{
                              <<"from">> => <<"Admin <admin@localhost>">>,
                              <<"to">> => [<<"foo@example.com">>],
                              <<"extra-headers">> => #{},
                              <<"body">> => <<"This is a mail">>},
                          <<"smtp">> => #{
                              <<"relay">> => <<"smtp.localdomain">>,
                              <<"port">> => 25,
                              <<"username">> => <<"username">>,
                              <<"password">> => <<"password">>
                             },
                          <<"error">> => #{
                              <<"to">> => <<"Email <user@localhost>">>,
                              <<"subject">> => <<"An error e-mail">>,
                              <<"body">> => <<"Further e-mail information">>
                             }}).

all() ->
    [
     parse
    ].

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

parse(_Config) ->
    {ok, SmtpEvent} = qpusherl_smtp_event:parse(?RAW_MAIL_EVENT, [{error_from, <<"admin@no.host">>}]),
    ?assertMatch({smtp_event,
                  {mail, <<"<admin@localhost>">>, [<<"<foo@example.com>">>], _},
                  {smtp, <<"smtp.localdomain">>, 25, <<"username">>, <<"password">>},
                  {mailerror,
                   <<"Email <user@localhost>">>,
                   <<"admin@no.host">>,
                   <<"An error e-mail">>,
                   _,
                   _}
                 }, SmtpEvent),
    ?assertMatch({_FromMail, _ToAddress, _Mail}, qpusherl_smtp_event:get_mail(SmtpEvent)),
    ?assertMatch({_FromMail, _ToAddress, _Mail}, qpusherl_smtp_event:get_error_mail(SmtpEvent, [])),
    ?assertMatch([{relay, _}, {port, _}, {username, _}, {password, _}],
                 qpusherl_smtp_event:get_smtp_options(SmtpEvent)),
    ok.
