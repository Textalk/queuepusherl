-module(smtp_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("queuepusherl_events.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([send_email/1]).
-export([parse_event/1]).
-export([failed_parse/1]).
-export([bad_email/1]).

-define(MAIL_EVENT, #mailevent{
                       mail = {<<"Foo Bar <foo@bar.baz>">>,
                               [<<"apa@bar.baz">>, <<"bepa@bar.baz">>],
                               <<"This is the mail content">>},
                       smtp = #smtpoptions{
                                 relay = <<"relay.bar.baz">>,
                                 port = 25,
                                 username = <<"user">>,
                                 password = <<"password">>
                                },
                       error = #mailerror{
                                  to = <<"foo@bar.baz">>,
                                  subject = <<"Error!">>,
                                  body = <<"This action generated an error">>
                                 }
                      }).
-define(MAIL_JSON, jiffy:encode(#{
                     type => smtp,
                     data => #{
                       mail => #{
                         from => <<"foo@bar.baz">>,
                         to => [
                                <<"apa@bar.baz">>,
                                <<"bepa@bar.baz">>
                               ],
                         cc => [
                               ],
                         bcc => [
                                ],
                         body => <<"This is the mail content">>
                        },
                       smtp => #{
                         relay => <<"relay.bar.baz">>,
                         port => 25,
                         username => <<"user">>,
                         password => <<"password">>
                        },
                       error => #{
                         to => <<"foo@bar.baz">>,
                         subject => <<"Error!">>,
                         body => <<"This action generated an error">>
                        }
                      }
                    })).
-define(MAIL_BAD_JSON, <<"{\"type\": \"smtp\","
                          "\"data\": {\"mail\": {},"
                                     "\"smtp\": {},"
                                     "\"error\": {}}}">>).

all() ->
    [send_email, parse_event, failed_parse, bad_email].

init_per_testcase(_Testcase, Config) ->
    Config.

end_per_testcase(_Testcase, Config) ->
    Config.

send_email(_Config) ->
    meck:new(gen_smtp_client),
    meck:expect(gen_smtp_client, send_blocking,
                fun (A, B) ->
                        ?assertMatch({_, [_, _], _}, A),
                        ?assertMatch([{relay, _}, {port, _}, {username, _}, {password, _}], B),
                        <<>> end),

    State = {state,
             ?MAIL_EVENT, % event
             0,           % retry_count
             0,           % max_retries
             0,           % initial_delay
             []           % errors
             },
    ?assertMatch({stop, normal, _},
                 queuepusherl_smtp_worker:handle_info(retry, State)),

    ?assertEqual(1, meck:num_calls(gen_smtp_client, send_blocking, '_')),

    meck:unload(gen_smtp_client).

parse_event(_Config) ->
    ?assertMatch({ok, {smtp, {{_, _, _}, _, _}}},  queuepusherl_event:parse(?MAIL_JSON)),
    ok.

failed_parse(_Config) ->
    ?assertMatch({error, _, _}, queuepusherl_event:parse(?MAIL_BAD_JSON)),
    ?assertMatch({error, {error, {_, truncated_json}}, _}, queuepusherl_event:parse(<<"{">>)),
    ok.

bad_email(_Config) ->
    ?assertThrow({invalid_email, <<"foo">>},
                 queuepusherl_smtp_event:parse(#{
                   <<"mail">> => #{
                       <<"from">> => <<"foo">>,
                       <<"body">> => <<"mail body">>
                      },
                   <<"smtp">> => #{
                       <<"relay">> => <<"">>,
                       <<"port">> => 0,
                       <<"username">> => <<"">>,
                       <<"password">> => <<"">>
                      },
                   <<"error">> => #{
                       <<"to">> => <<"">>,
                       <<"subject">> => <<"">>,
                       <<"body">> => <<"">>
                      }
                  })),
    ok.

