-module(http_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../deps/amqp_client/include/amqp_client.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([parse_test_1/1]).
-export([parse_test_2/1]).
-export([parse_test_3/1]).
-export([process_request_success/1]).
-export([process_request_fail/1]).

all() ->
    [
     parse_test_1,
     parse_test_2,
     parse_test_3,
     process_request_success,
     process_request_fail
    ].

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

parse_test_1(_Config) ->
    {ok, Event} = qpusherl_http_event:parse(
                    #{<<"request">> =>
                      #{<<"method">> => <<"GET">>,
                        <<"query">> => #{<<"kepa">> => <<"cepa">>, <<"gripa">> => true},
                        <<"data">> => #{<<"foo">> => <<"bar">>},
                        <<"url">> => <<"http://localhost:8080/foo?foo=bar&apa=bepa">>}}, []),
    Req = qpusherl_http_event:get_request(Event),
    ?assertMatch(#{data := <<"foo=bar">>,
                   headers := #{},
                   method := get,
                   require_success := false,
                   url := <<"http://localhost:8080/foo?foo=bar&apa=bepa&gripa&kepa=cepa">>},
                 Req),
    ok.

parse_test_2(_Config) ->
    {ok, Event} = qpusherl_http_event:parse(
                    #{<<"request">> =>
                      #{<<"method">> => <<"POST">>,
                        <<"query">> => #{},
                        <<"data">> => <<"this is some data">>,
                        <<"url">> => <<"https://localhost#foobar">>}}, []),
    Req = qpusherl_http_event:get_request(Event),
    ?assertMatch(#{data := <<"this is some data">>,
                   headers := #{},
                   method := post,
                   require_success := false,
                   url := <<"https://localhost/#foobar">>},
                 Req),
    ok.

parse_test_3(_Config) ->
    {ok, Event} = qpusherl_http_event:parse(
                    #{<<"request">> =>
                      #{<<"method">> => <<"GET">>,
                        <<"content-type">> => <<"application/json">>,
                        <<"data">> => #{<<"foo">> => <<"bar">>},
                        <<"url">> => <<"http://localhost:8000/foo">>
                       }
                     },
                    []
                   ),
    Req = qpusherl_http_event:get_request(Event),
    ?assertMatch(#{data := <<"{\"foo\":\"bar\"}">>}, Req),
    ok.

process_request_success(_Config) ->
    meck:new(httpc, []),
    meck:expect(httpc, request, fun(get, {"http://localhost/?foo=bar", []},
                                    _HttpOptions, _Options) ->
                                        {ok, {{<<"HTTP1.1">>, 200, <<"Ok">>}, [], <<"Response">>}}
                                end),
    Event = {http_event, #{method => get,
                           headers => #{},
                           content_type => <<>>,
                           data => <<>>,
                           require_success => false,
                           url => <<"http://localhost/?foo=bar">>}},
    ?assertEqual(ok, qpusherl_http_worker:process_event(Event)),
    %meck:validate(httpc),
    meck:unload(httpc),
    ok.

process_request_fail(_Config) ->
    meck:new(httpc, []),
    meck:expect(httpc, request, fun(get, {"http://localhost/?foo=bar", []},
                                    _HttpOptions, _Options) ->
                                        {error, {could_not_connect, <<>>}}
                                end),
    Event = {http_event, #{method => get,
                           headers => #{},
                           content_type => <<>>,
                           data => <<>>,
                           require_success => false,
                           url => <<"http://localhost/?foo=bar">>}},
    ?assertEqual({error, connection_failed, {could_not_connect, <<>>}},
                 qpusherl_http_worker:process_event(Event)),
    %meck:validate(httpc),
    meck:unload(httpc),
    ok.
