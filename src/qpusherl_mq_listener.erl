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

-define(SUBSCRIPTION_TIMEOUT, 10000).

-type rabbitmq_tag() :: integer().

-record(msgstate, {
          tag         :: rabbitmq_tag(),
          retries = 0 :: non_neg_integer(),
          payload     :: binary(),
          errors = [] :: [{atom(), binary()}]
         }).
-type msgstate() :: #msgstate{}.

-record(state, {
          connection              :: {pid(), term()} | undefined,
          channel                 :: {pid(), term()} | undefined,
          events = #{}            :: #{rabbitmq_tag() => msgstate()},
          workers = #{}           :: #{pid() => rabbitmq_tag()},
          oldworkers = sets:new() :: sets:set(pid()),
          config = []             :: [{atom(), term()}]
         }).


%% API.

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% gen_server.

init([]) ->
    lager:info("Message queue listener started!"),
    Get = fun (Key, Default) ->
                  case application:get_env(queuepusherl, Key) of
                      {ok, Value} -> {Key, Value};
                      error -> {Key, Default}
                  end
          end,
    Config = [Get(rabbitmq_fail, undefined),
              Get(rabbitmq_work, undefined),
              Get(rabbitmq_retry, undefined),
              Get(rabbitmq_routing_key, undefined),
              Get(rabbitmq_configs, undefined),
              Get(rabbitmq_reconnect_timeout, undefined),
              Get(event_attempt_count, undefined),
              Get(error_from, undefined),
              Get(error_smtp, undefined)
             ],
    self() ! connect,
    {ok, #state{config = Config}}.

get_config(Key, #state{config = Config}) ->
    proplists:get_value(Key, Config, undefined).

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

%% @doc Acknowledge completion event to rabbitmq
ack_event(#msgstate{tag = Tag}, #state{channel = {Channel, _}} = State) ->
    Ack = #'basic.ack'{delivery_tag = Tag},
    amqp_channel:call(Channel, Ack),
    State.

%% @doc Move the event to the retry queue
queue_retry_event(#msgstate{tag = Tag, errors = Errors} = MsgState,
                  #state{channel = {Channel, _}} = State) ->
    case Errors of
        [] -> ok;
        _ -> lager:info("Message ~p delayed for further retry: ~p", [Tag, Errors])
    end,
    Reject = #'basic.reject'{delivery_tag = Tag, requeue = false},
    amqp_channel:cast(Channel, Reject),
    remove_event(MsgState, State).

%% @doc Reject event without further attempts to retry.
reject_event(#msgstate{tag = Tag} = MsgState, State) ->
    lager:info("Stop retrying event (~p)", [Tag]),
    State1 = ack_event(MsgState, State),
    State2 = send_fail(MsgState, State1),
    remove_event(MsgState, State2).

%% @doc Send a new message to the fail queue.
send_fail(#msgstate{payload = Payload, errors = Errors},
          #state{channel = {Channel, _}} = State) ->
    lager:info("Sending fail-event to message queue", []),
    AppFail = get_config(rabbitmq_fail, State),
    Exchange = proplists:get_value(exchange, AppFail),
    RoutingKey = proplists:get_value(routing_key, AppFail),
    Publish = #'basic.publish'{exchange = Exchange, routing_key = RoutingKey},
    AmqpErrors = [{<<"qpush-error">>, array,
                   lists:map(fun (E) ->
                                     {longstr, erlang:list_to_binary(io_lib:format("~p", [E]))}
                             end,
                             [Errors])}],
    Props = #'P_basic'{
               delivery_mode = 2,
               headers = AmqpErrors
              },
    Msg = #amqp_msg{props = Props, payload = Payload},
    amqp_channel:cast(Channel, Publish, Msg),
    State.

% @doc Handle incoming messages from system, RabbitMQ and workers.
handle_info({'DOWN', MRef, process, _Worker, Reason},
            #state{connection = {_, ConM}, channel = {_, ChanM}} = State) when
      MRef == ConM; MRef == ChanM ->
    lager:error("RabbitMQ connection or channel is down: ~p~n", [Reason]),
    {stop, rabbitmq_down, State#state{connection = undefined, channel = undefined}};
handle_info({'DOWN', _MRef, process, Worker, Reason}, State = #state{}) ->
    case is_old_worker(Worker, State) of
        true ->
            lager:debug("Got expected DOWN signal from worker (~p)", [Worker]),
            {noreply, clear_old_worker(Worker, State)};
        false ->
            Message = case Reason of
                          normal ->
                              lager:warning("Got worker failed signal from ~p",
                                            [Worker]),
                              <<"Worker stopped">>;
                          _ ->
                              lager:warning("Got worker crashed signal from ~p: ~p",
                                            [Worker, Reason]),
                              <<"Worker crashed">>
                      end,
            State2 = case get_worker_event(Worker, State) of
                         {ok, MsgState} ->
                             MsgState1 = add_error(MsgState, {worker_failed, Message}),
                             reject_event(MsgState1, State);
                         error ->
                             State
                     end,
            State3 = remove_worker(Worker, State2), % Remove worker without retireing
            {noreply, State3}
    end;
handle_info({worker_finished, {Worker, Error}}, #state{} = State) ->
    %% Event failed!
    State1 = case get_worker_event(Worker, State) of
                 {ok, #msgstate{retries = 0} = MsgState} ->
                     Worker ! {stop, Error},
                     lager:error("Worker failed with no more retries (~p)", [Worker]),
                     MsgState1 = add_error(MsgState, Error),
                     reject_event(MsgState1, State);
                 {ok, #msgstate{retries = AttemptsLeft} = MsgState} ->
                     Worker ! stop,
                     lager:info("Worker failed with ~p more retries (~p)",
                                [AttemptsLeft, Worker]),
                     MsgState1 = add_error(MsgState, Error),
                     queue_retry_event(MsgState1, State);
                 error ->
                     lager:error("Could not match an event to the worker (~p)", [Worker]),
                     State
             end,
    {noreply, retire_worker(Worker, State1)};
handle_info({worker_finished, Worker}, #state{} = State) ->
    State1 = case get_worker_event(Worker, State) of
                 {ok, MsgState} ->
                     %% Event finished!
                     lager:info("Worker finished (~p)", [Worker]),
                     State2 = ack_event(MsgState, State),
                     Worker ! stop,
                     retire_worker(Worker, State2);
                 error ->
                     lager:error("Unknown worker finished! (~p)", [Worker]),
                     State
             end,
    {noreply, State1};
handle_info(connect, #state{connection = undefined} = State) ->
    % Setup connection to RabbitMQ and connect.
    RabbitConfigs = get_config(rabbitmq_configs, State),
    ReconnectDelay = get_config(rabbitmq_reconnect_timeout, State),
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
            erlang:send_after(ReconnectDelay, self(), connect),
            {noreply, State}
    end;
handle_info({#'basic.deliver'{delivery_tag = Tag},
             #amqp_msg{props = #'P_basic'{headers = AmqpHeaders}, payload = Payload}},
            #state{config = Config} = State) ->
    %% Handles incoming messages from RabbitMQ.
    AppWork = get_config(rabbitmq_work, State),
    MaxAttempts = get_config(event_attempt_count, State),
    WorkQueue = proplists:get_value(queue, AppWork),
    Headers = simplify_amqp_headers(AmqpHeaders),
    Requeues = amqp_headers_count_retries(Headers, WorkQueue, <<"rejected">>),
    FRequeues = math:log(float(Requeues) + 1) / math:log(2),
    Attempt = round(FRequeues),
    DelayFurher = FRequeues /= float(Attempt),
    AttemptsLeft = MaxAttempts - Attempt,
    MsgState = #msgstate{tag = Tag,
                         retries = AttemptsLeft,
                         payload = Payload},
    case DelayFurher of
        true ->
            lager:debug("Delay message ~p for exponential delay", [Tag]),
            State1 = queue_retry_event(MsgState, State),
            {noreply, State1};
        false ->
            case qpusherl_event:parse(Payload, Config) of
                {ok, Event} ->
                    lager:notice("Processing new message: ~p (attempts left: ~p)", [Tag, AttemptsLeft]),
                    {ok, Worker} = create_worker(Tag, Event, State),
                    State1 = add_event(MsgState, State),
                    {noreply, store_worker(Worker, Tag, State1)};
                {error, Reason, Message} ->
                    lager:error("Invalid qpusherl message:~n"
                                "Payload: ~p~n"
                                "Reason: ~p~n",
                                [Payload, Reason]),
                    MsgState1 = add_error(MsgState, {Reason, Message}),
                    State1 = reject_event(MsgState1, State),
                    {noreply, State1};
                false ->
                    lager:error("Could not execute event, retried too many times: ~n~p~nPayload: ~s",
                                [Headers, Payload]),
                    MsgState1 = add_error(MsgState, {execution_failed, <<"Could not execute event">>}),
                    State1 = reject_event(MsgState1, State),
                    {noreply, State1}
            end
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

create_worker(Tag, Event, #state{config = _Config}) ->
    {ok, Worker} = qpusherl_worker_sup:create_child(self(), Event),
    lager:debug("Started new worker! (~p :: ~p)", [Tag, Worker]),
    monitor(process, Worker),
    Worker ! execute,
    {ok, Worker}.

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
    AppWork = get_config(queuepusherl, rabbitmq_work), % <<"queuepusherl">>
    AppFail = get_config(queuepusherl, rabbitmq_fail),
    AppRetry = get_config(queuepusherl, rabbitmq_retry),
    RoutingKey = get_config(queuepusherl, rabbitmq_routing_key),

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


%%% Functions for handling workers in state

%% @doc Add worker to the state
store_worker(Worker, Tag, #state{workers = Workers} = State) ->
    State#state{workers = maps:put(Worker, Tag, Workers)}.

%% @doc Remove worker from state
remove_worker(Worker, State = #state{workers = Workers}) ->
    State1 = case get_worker_event(Worker, State) of
                 {ok, MsgState} ->
                     remove_event(MsgState, State);
                 error ->
                     State
             end,
    State1#state{workers = maps:remove(Worker, Workers)}.

%% @doc Move worker from workers to oldworkers for it to wait for the worker process to terminate
retire_worker(Worker, #state{oldworkers = OldWorkers} = State) ->
    case is_worker(Worker, State) of
        true ->
            State1 = remove_worker(Worker, State),
            State1#state{oldworkers = sets:add_element(Worker, OldWorkers)};
        false ->
            State
    end.

is_worker(Worker, #state{workers = Workers}) ->
    maps:is_key(Worker, Workers).

is_old_worker(Worker, #state{oldworkers = OldWorkers}) ->
    sets:is_element(Worker, OldWorkers).

clear_old_worker(Worker, #state{oldworkers = OldWorkers} = State) ->
    State1 = remove_worker(Worker, State),
    State1#state{oldworkers = sets:del_element(Worker, OldWorkers)}.


%%% Functions for handling events in state

get_event(Tag, #state{events = Events}) ->
    maps:find(Tag, Events).

get_worker_event(Worker, #state{workers = Workers} = State) ->
    case maps:find(Worker, Workers) of
        {ok, Tag} ->
            get_event(Tag, State);
        error ->
            error
    end.

add_event(#msgstate{tag = Tag} = MsgState, #state{events = Events} = State) ->
    State#state{events = maps:put(Tag, MsgState, Events)}.

remove_event(#msgstate{tag = Tag}, State) ->
    remove_event(Tag, State);
remove_event(Tag, #state{events = Events} = State) ->
    State#state{events = maps:remove(Tag, Events)}.

add_error(#msgstate{errors = Errors} = MsgState, Error) ->
    MsgState#msgstate{errors = [Error|Errors]}.

