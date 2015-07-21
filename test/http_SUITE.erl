-module(http_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../deps/amqp_client/include/amqp_client.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([parse_test_1/1]).
-export([parse_test_2/1]).

all() ->
    [
     parse_test_1,
     parse_test_2
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
                        <<"data">> => #{},
                        <<"url">> => <<"http://localhost:8080/foo?foo=bar&apa=bepa">>}}),
    Req = qpusherl_http_event:get_request(Event),
    ?assertMatch(#{data := <<>>,
                   method := get,
                   url := <<"http://localhost:8080/foo?foo=bar&apa=bepa&gripa&kepa=cepa">>},
                 Req),
    ?debugVal(Req),
    ok.

parse_test_2(_Config) ->
    {ok, Event} = qpusherl_http_event:parse(
                    #{<<"request">> =>
                      #{<<"method">> => <<"POST">>,
                        <<"query">> => #{},
                        <<"data">> => <<"this is some data">>,
                        <<"url">> => <<"https://localhost#foobar">>}}),
    Req = qpusherl_http_event:get_request(Event),
    ?assertMatch(#{data := <<"this is some data">>,
                   method := post,
                   url := <<"https://localhost/#foobar">>},
                 Req),
    ?debugVal(Req),
    ok.
