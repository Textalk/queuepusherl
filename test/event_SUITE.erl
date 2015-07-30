-module(event_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../deps/amqp_client/include/amqp_client.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([parse/1]).
-export([execute_http_event_success/1]).
-export([execute_smtp_event_success/1]).
-export([execute_http_event_failed/1]).
-export([execute_smtp_event_failed/1]).

groups() ->
    [{smtp_event, [],
      [execute_smtp_event_success,
       execute_smtp_event_failed]},
     {http_event, [],
      [execute_http_event_success,
       execute_http_event_failed]}
    ].

all() ->
    [
     parse,
     {group, smtp_event},
     {group, http_event}
    ].

-define(MAIL_EVENT, <<"{"
                      "  \"type\": \"smtp\","
                      "  \"data\": {"
                      "    \"mail\": {"
                      "      \"from\": \"some@mail.com\","
                      "      \"to\": ["
                      "        \"other@mail.com\""
                      "      ],"
                      "      \"extra-headers\": {"
                      "        \"subject\": \"This is a mail\""
                      "      },"
                      "      \"body\": \"This is a mail body\""
                      "    },"
                      "    \"smtp\": {"
                      "      \"relay\": \"no.where.else\","
                      "      \"port\": 25,"
                      "      \"username\": \"user\","
                      "      \"password\": \"errorsecret\""
                      "    },"
                      "    \"error\": {"
                      "      \"to\": \"error@local.domain\","
                      "      \"subject\": \"An error happened\","
                      "      \"body\": \"Explain the error:\""
                      "    }"
                      "  }"
                      "}">>).

-define(HTTP_GET_EVENT, <<"{"
                          "  \"type\": \"http\","
                          "  \"data\": {"
                          "    \"request\": {"
                          "      \"method\": \"GET\","
                          "      \"url\": \"http://localhost\","
                          "      \"require-success\": true,"
                          "      \"extra-headers\": { },"
                          "      \"query\": {"
                          "        \"foo\": \"bar\""
                          "      }"
                          "    },"
                          "    \"error\": {}"
                          "  }"
                          "}">>).

-define(HTTP_POST_EVENT, <<"{"
                           "  \"type\": \"http\","
                           "  \"data\": {"
                           "    \"request\": {"
                           "      \"method\": \"POST\","
                           "      \"url\": \"http://localhost\","
                           "      \"require-success\": true,"
                           "      \"extra-headers\": { },"
                           "      \"content-type\": \"application/json\","
                           "      \"data\": \"{}\""
                           "    },"
                           "    \"error\": {}"
                           "  }"
                           "}">>).

-define(PARSE_CONFIG, [{error_from, <<"admin@localhost">>},
                       {error_smtp, [{relay, <<"some.where.else">>},
                                     {port, 25},
                                     {username, <<"user">>},
                                     {password, <<"secret">>}
                                    ]}
                      ]).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

parse(_Config) ->
    {ok, ParsedEvent0} = qpusherl_event:parse(?MAIL_EVENT, ?PARSE_CONFIG),
    % smtp_SUITE already handles making sure that smtp_events are correct so no need to validate
    % that here.
    ?assertMatch({smtp, {smtp_event, _, _, _}}, ParsedEvent0),
    {ok, ParsedEvent1} = qpusherl_event:parse(?HTTP_GET_EVENT, ?PARSE_CONFIG),
    ?assertMatch({http, {http_event, #{method := get}}}, ParsedEvent1),
    {ok, ParsedEvent2} = qpusherl_event:parse(?HTTP_POST_EVENT, ?PARSE_CONFIG),
    ?assertMatch({http, {http_event, #{method := post}}}, ParsedEvent2),
    ok.

execute_http_event_success(_Config) ->
    {ok, Event} = qpusherl_event:parse(?HTTP_GET_EVENT, ?PARSE_CONFIG),

    meck:new(httpc, []),
    meck:expect(httpc, request,
                fun (_Method, _Req, _HttpOpt, _Opt) ->
                        {ok, {{<<"HTTP1.1">>, 200, <<"OK">>}, [], <<>>}}
                end),
    {ok, State0} = qpusherl_event_worker:init([self(), Event]),
    ?assertMatch({state, _, _, false, _}, State0),
    {noreply, State1} = qpusherl_event_worker:handle_info(execute, State0),
    Return = receive {worker_finished, X} -> X end,
    ?assert(is_pid(Return)),
    ?assertMatch({state, _, _, true, _}, State1),

    ?assert(meck:validate(httpc)),
    meck:unload(httpc),
    ok.

execute_smtp_event_success(_Config) ->
    {ok, Event} = qpusherl_event:parse(?MAIL_EVENT, ?PARSE_CONFIG),

    meck:new(gen_smtp_client, []),
    meck:expect(gen_smtp_client, send_blocking,
                fun (_Mail, _Smtp) ->
                        <<"fake receipt">>
                end),
    {ok, State0} = qpusherl_event_worker:init([self(), Event]),
    ?assertMatch({state, _, _, false, _}, State0),
    {noreply, State1} = qpusherl_event_worker:handle_info(execute, State0),
    Return = receive {worker_finished, Y} -> Y end,
    ?assert(is_pid(Return)),
    ?assertMatch({state, _, _, true, _}, State1),

    ?assert(meck:validate(gen_smtp_client)),
    meck:unload(gen_smtp_client),

    ok.

execute_http_event_failed(_Config) ->
    {ok, Event} = qpusherl_event:parse(?HTTP_GET_EVENT, ?PARSE_CONFIG),

    meck:new(httpc, []),
    meck:expect(httpc, request,
                fun (_Method, _Req, _HttpOpt, _Opt) ->
                        {error, <<"Test fail">>}
                end),
    {ok, State0} = qpusherl_event_worker:init([self(), Event]),
    ?assertMatch({state, _, _, false, _}, State0),
    {noreply, State1} = qpusherl_event_worker:handle_info(execute, State0),
    {Return, Error} = receive {worker_finished, X} -> X end,
    ?assert(is_pid(Return)),
    ?assertMatch({state, _, _, true, _}, State1),
    ?assertMatch({connection_failed, <<"Test fail">>}, Error),

    ?assert(meck:validate(httpc)),
    meck:unload(httpc),

    ok.

execute_smtp_event_failed(_Config) ->
    {ok, Event} = qpusherl_event:parse(?MAIL_EVENT, ?PARSE_CONFIG),

    meck:new(gen_smtp_client, []),
    meck:expect(gen_smtp_client, send_blocking,
                fun ({<<"<some@mail.com>">>, _To, _Body}, _Smtp) ->
                        {error, test_error, <<"Test error">>}
                end),
    {ok, State0} = qpusherl_event_worker:init([self(), Event]),
    ?assertMatch({state, _, _, false, _}, State0),
    {noreply, State1} = qpusherl_event_worker:handle_info(execute, State0),
    {Return, Error} = receive {worker_finished, Y} -> Y end,
    ?assert(is_pid(Return)),
    ?assertMatch({state, _, _, true, _}, State1),
    ?assertMatch({test_error, <<"Test error">>}, Error),

    ?assert(meck:validate(gen_smtp_client)),

    meck:expect(gen_smtp_client, send_blocking,
                fun ({<<"<admin@localhost>">>, _To, _Body}, _Smtp) ->
                        <<"Test receipt">>
                end),
    {stop, normal, _State} = qpusherl_event_worker:handle_info(
                               {stop, [Error]},
                               State1),

    ?assert(meck:validate(gen_smtp_client)),
    meck:unload(gen_smtp_client),

    ok.
