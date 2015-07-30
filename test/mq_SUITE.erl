-module(mq_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../deps/amqp_client/include/amqp_client.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([connect/1]).

all() ->
    [
     connect
    ].

-define(RABBITMQ_CONFIGS, [{rabbitmq_work, [
                                    {queue, <<"test.work">>},
                                    {exchange, <<"test.exchange">>}
                                   ]},
                   {rabbitmq_fail, [
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
                   {rabbitmq_reconnect_timeout, <<>>}
                  ]). 

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

fake_connection() ->
    receive
        stop ->
            ok;
        Incoming ->
            lager:info("FAKE CONNECTION: ~p", [Incoming]),
            fake_connection()
    end.

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
                        {ok, spawn(fun fake_connection/0)}
                end),
    meck:expect(amqp_connection, open_channel,
                fun(_Conn) ->
                        {ok, spawn(fun fake_connection/0)}
                end),
    meck:expect(amqp_channel, call, fun (_Channel, Decl) ->
                                            case tuple_to_list(Decl) of
                                                ['exchange.declare'|_] ->
                                                    {'exchange.declare_ok'};
                                                ['queue.declare'|_] ->
                                                    {'queue.declare_ok', '_', '_', '_'};
                                                ['queue.bind'|_] ->
                                                    {'queue.bind_ok'}
                                            end
                                    end),
    meck:expect(amqp_channel, subscribe, fun(_Channel, _Subscription, _Receiver) ->
                                                 {'basic.consume_ok', 0}
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
