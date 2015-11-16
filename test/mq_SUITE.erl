-module(mq_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../deps/amqp_client/include/amqp_client.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([connect/1]).
-export([retry_event/1]).
-export([deliver_test_fail/1]).
-export([deliver_http_test_success/1]).

all() ->
    [
     connect,
     retry_event,
     deliver_test_fail,
     deliver_http_test_success
    ].

-define(RABBITMQ_CONFIGS, [{rabbitmq_work, [
                                    {queue, <<"test.work">>},
                                    {exchange, <<"test.exchange">>}
                                   ]},
                   {rabbitmq_response, [
                                    {queue, <<"test.fail">>},
                                    {exchange, <<"test.exchange">>},
                                    {routing_key, <<"fail_test_key">>}
                                   ]},
                   {rabbitmq_retry, [
                                     {queue, <<"test.retry">>},
                                     {exchange, <<"test.exchange">>},
                                     {timeout, 10000}
                                    ]},
                   {rabbitmq_routing_key, <<"test_key">>},
                   {rabbitmq_configs, [[
                                        {username, <<"guest">>},
                                        {password, <<"guest">>},
                                        {vhost, <<"/">>},
                                        {host, "localhost"},
                                        {port, 5672}
                                       ]]},
                   {rabbitmq_reconnect_timeout, <<>>},
                   {event_attempt_count, 3}
                  ]).

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

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

fake_connection([]) ->
    ok;
fake_connection([Signal|Rest]) ->
    receive
        Signal ->
            fake_connection(Rest);
        Unknown ->
            ct:pal("Got unexpected signal: ~p", [Unknown]),
            ?assert(false),
            ok
    end.

%% @doc This tests setting up the connection to RabbitMQ and all the queues.
connect(_Config) ->
    State0 = {state,
              undefined,        % connection
              undefined,        % channel
              #{},              % events
              #{},              % workers
              sets:new(),       % oldworkers
              ?RABBITMQ_CONFIGS % config
             },

    meck:new(amqp_connection, []),
    meck:new(amqp_channel, []),

    meck:expect(amqp_connection, start,
                fun (_ConnParams) ->
                        {ok, spawn(fun () -> fake_connection([stop]) end)}
                end),
    meck:expect(amqp_connection, open_channel,
                fun(_Conn) ->
                        {ok, spawn(fun () -> fake_connection([stop]) end)}
                end),
    meck:expect(amqp_channel, call, fun (_Channel, Decl) ->
                                            case Decl of
                                                #'exchange.declare'{} ->
                                                    #'exchange.declare_ok'{};
                                                #'queue.declare'{} ->
                                                    #'queue.declare_ok'{};
                                                #'queue.bind'{} ->
                                                    #'queue.bind_ok'{}
                                            end
                                    end),
    meck:expect(amqp_channel, subscribe, fun(_Channel, _Subscription, _Receiver) ->
                                                 #'basic.consume_ok'{consumer_tag = 0}
                                         end),
    self() ! {'basic.consume_ok', 0},  %% We need to send this message for future use!
    {noreply, State1} = qpusherl_mq_listener:handle_info(connect, State0),

    ?assert(meck:validate(amqp_connection)),
    ?assert(meck:validate(amqp_channel)),

    meck:expect(amqp_connection, close,
                fun (Connection) ->
                        Connection ! stop
                end),
    meck:expect(amqp_channel, close,
                fun (Channel) ->
                        Channel ! stop
                end),

    qpusherl_mq_listener:terminate(normal, State1),

    ?assert(meck:validate(amqp_connection)),
    ?assert(meck:validate(amqp_channel)),

    meck:unload(amqp_channel),
    meck:unload(amqp_connection),

    ok.

%% @doc This tests receiving an invalid event from RabbitMQ. This should cause a fail message to be
%%      sent on the fail queue.
deliver_test_fail(_Config) ->
    State0 = {state,
              {fake_connection, connM}, % connection
              {fake_channel, chanM},    % channel
              #{},                      % events
              #{},                      % workers
              sets:new(),               % oldworkers
              ?RABBITMQ_CONFIGS         % config
             },
    BadPayload = <<"foobar">>,
    Headers = undefined,

    meck:new(amqp_channel),
    meck:expect(amqp_channel, call,
                fun (fake_channel, _Ack) ->
                        ok
                end),

    meck:expect(amqp_channel, cast,
                fun (fake_channel,
                     #'basic.publish'{routing_key = <<"fail_test_key">>},
                     #amqp_msg{payload = <<"foobar">>}) ->
                        ok
                end),

    {noreply, State1} = qpusherl_mq_listener:handle_info({#'basic.deliver'{delivery_tag = 0},
                                                          #amqp_msg{props = #'P_basic'{
                                                                               headers = Headers
                                                                              },
                                                                    payload = BadPayload}},
                                                         State0),
    ?assertMatch({state,
                  {fake_connection, connM},
                  {fake_channel, chanM},
                  #{}, #{},
                  _, _}, State1),

    ?assert(meck:validate(amqp_channel)),
    meck:unload(amqp_channel),

    ok.

%% @doc This tests receiving a valid HTTP GET event from RabbitMQ. This message should cause a
%%      worker to be started with the parsed version of the event as argument and then the worker
%%      should be added to the to the states dict of workers.
deliver_http_test_success(_Config) ->
    State0 = {state,
              {fake_connection, connM}, % connection
              {fake_channel, chanM},    % channel
              #{},                      % events
              #{},                      % workers
              sets:new(),               % oldworkers
              ?RABBITMQ_CONFIGS         % config
             },
    BadPayload = ?HTTP_GET_EVENT,
    Headers = [{<<"x-death">>, array,
                [{table,
                  [{<<"count">>, long, 1},
                   {<<"exchange">>, longstr, <<"test.exchange">>},
                   {<<"queue">>, longstr, <<"test.work">>},
                   {<<"reason">>, longstr, <<"rejected">>},
                   {<<"routing-keys">>, array, [{longstr, <<"test_key">>}]},
                   {<<"time">>, timestamp, 420000}
                  ]
                 }
                ]
               }
              ],
    Tag = 0,

    meck:new(qpusherl_worker_sup, []),

    meck:expect(qpusherl_worker_sup, create_child,
                fun (_Self, Event) ->
                        ?assertMatch({http, {http_event,
                                             #{method := get,
                                               url := <<"http://localhost/?foo=bar">>}}}, Event),
                        {ok, spawn(fun () -> fake_connection([execute, stop]) end)}
                end),

    {noreply, State1} = qpusherl_mq_listener:handle_info(
                          {#'basic.deliver'{delivery_tag = Tag},
                           #amqp_msg{props = #'P_basic'{headers = Headers},
                                     payload = BadPayload}},
                          State0),
    {state, _, _, Events, Workers, _, _} = State1,

    [FakeWorker] = maps:keys(Workers),
    ?assert(is_pid(FakeWorker)),
    ?assertMatch({state,
                  {fake_connection, connM},
                  {fake_channel, chanM},
                  #{}, #{},
                  _, _}, State1),
    case maps:find(Tag, Events) of
        {ok, MsgState} -> ?assertMatch({msgstate, Tag, 2, _, _, [], _}, MsgState)
    end,

    ?assert(meck:validate(qpusherl_worker_sup)),
    meck:unload(qpusherl_worker_sup),

    FakeWorker ! stop,

    ?assertEqual(ok, receive
                         {'DOWN', _MRef, process, FakeWorker, normal} -> ok
                     after
                         500 -> timeout
                     end),

    ok.

retry_event(_Config) ->
    Worker = spawn(fun () -> fake_connection([stop, {stop, fake_error}]) end),

    State0 = {state,
              {fake_connection, connM},
              {fake_channel, chanM},
              #{0 => {msgstate, 0, 3, <<"fake payload">>, [], [], []}},
              maps:from_list([{Worker, 0}]),
              sets:new(),
              ?RABBITMQ_CONFIGS
             },

    meck:new(amqp_channel),

    meck:expect(amqp_channel, cast,
                fun (fake_channel, #'basic.publish'{}, #amqp_msg{}) ->
                        ok
                end),

    meck:expect(amqp_channel, call,
                fun (fake_channel, #'basic.ack'{delivery_tag = 0}) ->
                        ok
                end),

    {noreply, State1} = qpusherl_mq_listener:handle_info(
                          {worker_finished, {success, Worker, <<"Fake success">>}},
                          State0
                         ),

    ?assertMatch({state, _, _, #{}, #{}, _, _}, State1),

    ?assert(meck:validate(amqp_channel)),

    State2 = {state,
              {fake_connection, connM},
              {fake_channel, chanM},
              #{1 => {msgstate, 1, 0, <<"fake payload">>, [], [], []}},
              maps:from_list([{Worker, 1}]),
              sets:new(),
              ?RABBITMQ_CONFIGS
             },

    meck:expect(amqp_channel, call,
                fun (fake_channel, #'basic.ack'{delivery_tag = 1}) ->
                        ok
                end),

    meck:expect(amqp_channel, cast,
                fun (fake_channel,
                     #'basic.reject'{delivery_tag = 1}) ->
                        ok
                end),

    %% Since the msgstate has 0 in retries we also expect a message on the fail queue.
    meck:expect(amqp_channel, cast,
                fun (fake_channel,
                     #'basic.publish'{routing_key = <<"fail_test_key">>},
                     #amqp_msg{payload = <<"fake payload">>}) ->
                        ok
                end),

    {noreply, State3} = qpusherl_mq_listener:handle_info(
                          {worker_finished, {fail, Worker, fake_error}},
                          State2
                         ),
    {state, _, _, Events, Workers, _, _} = State3,
    ?assertEqual(#{}, Events),
    ?assertEqual(#{}, Workers),

    ?assert(meck:validate(amqp_channel)),
    meck:unload(amqp_channel),

    ok.
