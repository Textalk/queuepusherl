-module(mq_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("queuepusherl_events.hrl").
-include("../deps/amqp_client/include/amqp_client.hrl").

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([simple_test/1]).

all() ->
    [simple_test].

init_per_testcase(_TestCase, Config) ->
    ClientConfig = #amqp_params_network{
                     username = <<"guest">>,
                     password = <<"guest">>,
                     host = "localhost",
                     port = 5672
                     },
    try
        Exchange = <<"amq.direct">>,
        {ok, Connection} = amqp_connection:start(ClientConfig),
        {ok, Channel} = amqp_connection:open_channel(Connection),
        #'exchange.declare_ok'{} = amqp_channel:call(Channel,
                                                     #'exchange.declare'{
                                                        exchange = Exchange,
                                                        durable = true
                                                       }),
        #'queue.declare_ok'{queue = Queue} = amqp_channel:call(Channel,
                                                               #'queue.declare'{
                                                                  queue = <<"queuepusherl">>,
                                                                  durable = true
                                                                 }),
        Binding = #'queue.bind'{queue = Queue,
                                exchange = Exchange,
                                routing_key = Queue},
        #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),
        add_config(rabbitmq, {Connection, Channel, Exchange, Queue}, Config)
    catch
        Class:Error ->
            ct:pal("Caught ~p: ~p", [Class, Error]),
            Config
    end.


end_per_testcase(_TestCase, Config) ->
    case get_config(rabbitmq, Config) of
        false -> ok;
        {Connection, Channel, Exchange, Queue} ->
            Binding = #'queue.unbind'{queue = Queue,
                                      exchange = Exchange,
                                      routing_key = Queue},
            #'queue.unbind_ok'{} = amqp_channel:call(Channel, Binding),
            catch amqp_channel:close(Channel),
            catch amqp_connection:close(Connection)
    end,
    del_config(rabbitmq, Config).

simple_test(Config) ->
    meck:new(queuepusherl_app, [passthrough]),
    meck:expect(queuepusherl_app, stop,
                fun (State) -> meck:passthrough([State]) end),
    meck:new(queuepusherl_mq_listener, [passthrough]),
    meck:expect(queuepusherl_mq_listener, handle_info,
                fun (Info, State) -> meck:passthrough([Info, State]) end),
    meck:expect(queuepusherl_mq_listener, terminate,
              fun (Reason, State) -> meck:passthrough([Reason, State]) end),
    {ok, Started} = application:ensure_all_started(queuepusherl),
    ct:pal("Started apps: ~p", [Started]),
    meck:wait(queuepusherl_mq_listener, handle_info, '_', 5000),
    case get_config(rabbitmq, Config) of
        {_Connection, Channel, Exchange, Queue} ->
            Payload = <<"{}">>,
            Publish = #'basic.publish'{exchange = Exchange, routing_key = Queue},
            amqp_channel:cast(Channel, Publish, #amqp_msg{payload = Payload});
        _ ->
            ok
    end,
    %ok = application:stop(queuepusherl),
    ct:pal("~p", [sys:get_state(list_to_pid("<0.142.0>"))]),
    ct:pal("Stopping all applications~n"),
    [ catch application:stop(App) || App <- lists:reverse(Started) ],
    ct:pal("Applications stopping.", []),
    %meck:wait(queuepusherl_mq_listener, terminate, '_', 5000),
    meck:wait(queuepusherl_app, stop, '_', 5000),
    ct:pal("All applications stopped.", []),
    ok = meck:unload(queuepusherl_mq_listener),
    ok = meck:unload(queuepusherl_app),
    ok.

add_config(Key, Value, Config) ->
    lists:keystore(Key, 1, Config, {Key, Value}).

del_config(Key, Config) ->
    lists:keydelete(Key, 1, Config).

get_config(Key, Config) ->
    case lists:keyfind(Key, 1, Config) of
        {Key, Value} -> Value;
        _ -> null
    end.
