-module(qpusherl_mq_listener).
-behaviour(gen_server).

%% API.
-export([start_link/0]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-include_lib("amqp_client/include/amqp_client.hrl").

-define(RECONNECT_TIMEOUT, 10000).
-define(SUBSCRIPTION_TIMEOUT, 10000).
-define(MAX_REQUEUES, 3).

-record(state, {
          connection              :: {pid(), term()} | undefined,
          channel                 :: {pid(), term()} | undefined,
          workers = #{}           :: map(),
          oldworkers = sets:new() :: sets:set()
         }).

%% API.

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% gen_server.

init([]) ->
    lager:info("Message queue listener started!"),
    self() ! connect,
    {ok, #state{}}.

terminate(Reason, #state{connection = {Connection, _}, channel = ChannelPair}) ->
    lager:warning("Message queue listener stopped: ~p~n", [Reason]),
    case ChannelPair of
        {Channel, _MRef} -> catch amqp_channel:close(Channel);
        _ -> ok
    end,
    catch amqp_connection:close(Connection),
    ok;
terminate(Reason, _State) ->
    lager:warning("Message queue listener failed: ~p", [Reason]),
    ok.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

% @doc Handle incoming messages from system, RabbitMQ and workers.
handle_info({'DOWN', MRef, process, _Worker, Reason},
            #state{connection = {_, ConM}, channel = {_, ChanM}} = State) when
      MRef == ConM; MRef == ChanM ->
    lager:error("RabbitMQ connection or channel is down: ~p~n", [Reason]),
    {stop, rabbitmq_down, State#state{connection = undefined, channel = undefined}};
handle_info({'DOWN', _MRef, process, Worker, Reason},
            #state{workers = Workers, oldworkers = OldWorkers} = State) ->
    % TODO: Fix possible issue with worker going down signal is received before the event_finished
    % message is received.
    case {maps:find(Worker, Workers), sets:is_element(Worker, OldWorkers)} of
        {{ok, {Tag, AttemptsLeft, Payload}}, _} ->
            case Reason of
                normal -> lager:warning("Got worker failed signal from ~p/~p",
                                        [Worker, Tag]);
                _ -> lager:warning("Got worker crashed signal from ~p/~p: ~p",
                                        [Worker, Tag, Reason])
            end,
            attempt_failed(Tag, AttemptsLeft, Payload, State),
            {noreply, State};
        {_, true} ->
            lager:info("Confirmed worker terminated correctly: ~p", [Worker]),
            {noreply, State#state{oldworkers = sets:del_element(Worker, OldWorkers)}};
        {_, false} ->
            lager:warning("Unknown process went down: ~p", [Worker]),
            {noreply, State}
    end;
handle_info({worker_finished, Worker}, State = #state{workers = Workers, oldworkers = OldWorkers}) ->
    case maps:find(Worker, Workers) of
        {ok, {Tag, _AttemptsLeft, _Payload}} ->
            send_ack(Tag, State),
            lager:notice("Event has been acked! (~p :: ~p)", [Tag, Worker]),
            {noreply, State#state{workers = maps:remove(Worker, Workers),
                                  oldworkers = sets:add_element(Worker, OldWorkers)}};
        error ->
            {noreply, State}
    end;
handle_info(connect, #state{connection = undefined} = State) ->
    % Setup connection to RabbitMQ and connect.
    {ok, RabbitConfigs} = application:get_env(queuepusherl, rabbitmq_configs),
    lager:info("Connecting to RabbitMQ"),
    case connect(RabbitConfigs) of
        {ok, Connection} ->
            ConM = monitor(process, Connection),
            {ok, Channel} = amqp_connection:open_channel(Connection),
            ChanM = monitor(process, Channel),
            ok = setup_subscriptions(Channel),
            lager:info("Established connection to RabbitMQ"),
            {noreply, State#state{connection = {Connection, ConM}, channel = {Channel, ChanM}}};
        {error, no_connection_to_mq} ->
            erlang:send_after(?RECONNECT_TIMEOUT, self(), connect),
            {noreply, State}
    end;
handle_info({#'basic.deliver'{delivery_tag = Tag},
             #amqp_msg{props = #'P_basic'{headers = AmqpHeaders},
                       payload = Payload}},
            State = #state{workers = Workers}) ->
    %% Handles incoming messages from RabbitMQ.
    {ok, AppWork} = application:get_env(queuepusherl, rabbitmq_work),
    {ok, MaxRequeues} = application:get_env(queuepusherl, event_requeue_count),
    WorkQueue = proplists:get_value(queue, AppWork),
    Headers = simplify_amqp_headers(AmqpHeaders),
    Requeues = amqp_headers_count_retries(Headers, WorkQueue, <<"rejected">>),
    AttemptsLeft = MaxRequeues - Requeues,
    case qpusherl_event:parse(Payload) of
        {ok, Event} ->
            lager:notice("Processing new message: ~p (attempts left: ~p)~n", [Tag, AttemptsLeft]),
            {ok, Worker} = add_worker(Tag, Event, AttemptsLeft),
            {noreply, State#state{workers = maps:put(Worker, {Tag, AttemptsLeft, Payload}, Workers)}};
        {error, Reason, _} ->
            lager:error("Invalid qpusherl message:~n"
                        "Payload: ~p~n"
                        "Reason: ~p~n",
                        [Payload, Reason]),
            send_fail(Payload, State),
            send_ack(Tag, State),
            {noreply, State};
        false ->
            lager:error("Could not execute event, retried too many times: ~n~p~nPayload: ~s",
                        [Headers, Payload]),
            send_fail(Payload, State),
            send_ack(Tag, State),
            {noreply, State}
    end;
handle_info(#'basic.cancel'{}, State) ->
    % Handles RabbitMQ going down. Nothing to worry about, just crash and restart.
    case State of
        #state{connection = {_, ConM}, channel = {_, ChanM}} ->
            demonitor(ConM),
            demonitor(ChanM);
        _ -> ok
    end,
    {stop, subscription_canceled, State#state{connection = undefined, channel = undefined}};
handle_info(Info, State) ->
    % Some other message to the server pid.
    lager:warning("~p ignoring info ~p", [?MODULE, Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

add_worker(Tag, Event, RetriesLeft) ->
    {ok, Worker} = qpusherl_worker_sup:create_child(self(), Event),
    lager:notice("Started new worker! (~p :: ~p)", [Tag, Worker]),
    monitor(process, Worker),
    Worker ! {execute, RetriesLeft},
    {ok, Worker}.

attempt_failed(Tag, AttemptsLeft, Payload, State)
  when AttemptsLeft =< 0 ->
    lager:notice("Event failed, give up completely", []),
    send_ack(Tag, State),
    send_fail(Payload, State);
attempt_failed(Tag, AttemptsLeft, _Payload, State) ->
    lager:notice("Event failed, retry ~p times", [AttemptsLeft - 1]),
    send_return(Tag, State).

send_fail(Payload, #state{channel = {Channel, _}}) ->
    {ok, AppFail} = application:get_env(queuepusherl, rabbitmq_fail),
    Exchange = proplists:get_value(exchange, AppFail),
    RoutingKey = proplists:get_value(routing_key, AppFail),
    Publish = #'basic.publish'{exchange = Exchange, routing_key = RoutingKey},
    Props = #'P_basic'{delivery_mode = 2},
    Msg = #amqp_msg{props = Props, payload = Payload},
    amqp_channel:cast(Channel, Publish, Msg).

send_return(Tag, #state{channel = {Channel, _}}) ->
    lager:notice("Message ~p delayed for further retry.", [Tag]),
    Reject = #'basic.reject'{delivery_tag = Tag, requeue = false},
    amqp_channel:call(Channel, Reject).

send_ack(Tag, #state{channel = {Channel, _}}) ->
    Ack = #'basic.ack'{delivery_tag = Tag},
    amqp_channel:call(Channel, Ack).

%% Connect to any of the RabbitMQ servers
-spec connect([list()]) -> {ok, pid()}.
connect([MQParams | Rest]) ->
    AmqpConnParams = #amqp_params_network{
                        username           = proplists:get_value(username, MQParams),
                        password           = proplists:get_value(password, MQParams),
                        virtual_host       = proplists:get_value(vhost, MQParams, <<"/">>),
                        host               = proplists:get_value(host, MQParams, "localhost"),
                        port               = proplists:get_value(port, MQParams, 5672),
                        heartbeat          = 5,
                        connection_timeout = 60000
                       },
    case amqp_connection:start(AmqpConnParams) of
        {ok, Connection} ->
            {ok, Connection};
        {error, Reason} ->
            lager:warning("Unable to connect to RabbitMQ broker"
                          " for reason ~p using config ~p.",
                          [Reason, MQParams]),
            connect(Rest)
    end;
connect([]) ->
    lager:error("Failed to connect to any RabbitMQ brokers."),
    {error, no_connection_to_mq}.

-record(subscription_info, {
          queue                        :: binary(),
          queue_durable = false        :: boolean(),
          exchange                     :: binary(),
          exchange_durable = false     :: boolean(),
          exchange_type = <<"direct">> :: binary(),
          dlx                          :: binary(),
          dlx_ttl                      :: non_neg_integer(),
          routing_key                  :: binary(),
          subscribe = false            :: boolean()
         }).

setup_subscriptions(Channel) ->
    {ok, AppWork}    = application:get_env(queuepusherl, rabbitmq_work), % <<"queuepusherl">>
    {ok, AppFail}    = application:get_env(queuepusherl, rabbitmq_fail),
    {ok, AppRetry}   = application:get_env(queuepusherl, rabbitmq_retry),
    {ok, RoutingKey} = application:get_env(queuepusherl, rabbitmq_routing_key),

    WorkQueue = proplists:get_value(queue, AppWork),
    WorkExchange = proplists:get_value(exchange, AppWork),

    FailQueue = proplists:get_value(queue, AppFail),
    FailExchange = proplists:get_value(exchange, AppFail),
    FailKey = proplists:get_value(routing_key, AppFail),

    RetryQueue = proplists:get_value(queue, AppRetry),
    RetryExchange = proplists:get_value(exchange, AppRetry),
    RetryTimeout = proplists:get_value(timeout, AppRetry),

    lager:info("Setting up subscription:~n"
               "Work queue: ~s @ ~s~n"
               "Fail queue: ~s @ ~s~n"
               "Retry queue: ~s @ ~s", [WorkQueue, WorkExchange,
                                        FailQueue, FailExchange,
                                        RetryQueue, RetryExchange]),

    ok = setup_subscription(Channel, #subscription_info{queue = WorkQueue,
                                                        queue_durable = true,
                                                        exchange = WorkExchange,
                                                        exchange_durable = true,
                                                        dlx = RetryExchange,
                                                        routing_key = RoutingKey,
                                                        subscribe = true}),

    ok = setup_subscription(Channel, #subscription_info{queue = FailQueue,
                                                        queue_durable = true,
                                                        exchange = FailExchange,
                                                        exchange_durable = true,
                                                        routing_key = FailKey}),

    ok = setup_subscription(Channel, #subscription_info{queue = RetryQueue,
                                                        exchange = RetryExchange,
                                                        dlx = WorkExchange,
                                                        dlx_ttl = RetryTimeout,
                                                        routing_key = RoutingKey,
                                                        subscribe = false}),
    ok.


setup_subscription(Channel, #subscription_info{queue = Queue,
                                               queue_durable = DurableQ,
                                               exchange = Exchange,
                                               exchange_durable = DurableE,
                                               exchange_type = ExchangeType,
                                               dlx = Deadletter,
                                               dlx_ttl = DeadletterTTL,
                                               routing_key = RoutingKey,
                                               subscribe = Subscribe
                                              }) ->
    ExchDecl = #'exchange.declare'{exchange = Exchange,
                                   durable = DurableE,
                                   type = ExchangeType},
    #'exchange.declare_ok'{} = amqp_channel:call(Channel, ExchDecl),

    Args = [{<<"x-dead-letter-exchange">>, longstr, Deadletter} || Deadletter /= undefined] ++
    [{<<"x-message-ttl">>, signedint, DeadletterTTL} || DeadletterTTL /= undefined],

    QueueDecl = #'queue.declare'{queue = Queue, durable = DurableQ, arguments = Args},
    #'queue.declare_ok'{} = amqp_channel:call(Channel, QueueDecl),

    BindDecl = #'queue.bind'{queue = Queue, exchange = Exchange, routing_key = RoutingKey},
    #'queue.bind_ok'{} = amqp_channel:call(Channel, BindDecl),

    if
        Subscribe ->
            Subscription = #'basic.consume'{queue = Queue},
            #'basic.consume_ok'{consumer_tag = Tag} = amqp_channel:subscribe(Channel,
                                                                             Subscription,
                                                                             self()),
            receive
                #'basic.consume_ok'{consumer_tag = Tag} -> ok
            after
                ?SUBSCRIPTION_TIMEOUT -> {error, timeout}
            end;
        true -> ok
    end.

simplify_amqp_headers(undefined) ->
    undefined;
simplify_amqp_headers(Headers) ->
    simplify_amqp_data({table, Headers}).

simplify_amqp_data({Name, Key, Value}) ->
    {Name, simplify_amqp_data({Key, Value})};
simplify_amqp_data({Key, Value})
  when Key == longstr; Key == long; Key == binary ->
    Value;
simplify_amqp_data({timestamp, Value}) ->
    {{Y, Mo, D}, {H, M, S}} = calendar:gregorian_seconds_to_datetime(Value),
    {1970 + Y, Mo, D + 1, H, M, S};
simplify_amqp_data({array, Array}) ->
    lists:map(fun simplify_amqp_data/1, Array);
simplify_amqp_data({table, Table}) ->
    maps:from_list(lists:map(fun simplify_amqp_data/1, Table)).

amqp_headers_count_retries(undefined, _, _) ->
    0;
amqp_headers_count_retries(#{<<"x-death">> := Deaths}, Queue, Reason) ->
    lists:foldl(fun (Death, PrevCount) ->
                        case Death of
                            #{<<"queue">> := Queue,
                              <<"reason">> := Reason,
                              <<"count">> := Count} -> Count;
                            _ -> PrevCount
                        end
                end, 0, Deaths).
