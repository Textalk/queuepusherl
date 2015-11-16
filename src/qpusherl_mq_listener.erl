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
          tag          :: rabbitmq_tag(),
          retries = 0  :: non_neg_integer(),
          payload      :: binary(),
          headers = [] :: term(),
          errors = []  :: [{atom(), binary()}],
          results = [] :: [binary()]
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
    Get = fun (Key) ->
                  {ok, Value} = application:get_env(queuepusherl, Key),
                  {Key, Value}
          end,
    Config = [Get(rabbitmq_response),
              Get(rabbitmq_work),
              Get(rabbitmq_retry),
              Get(rabbitmq_routing_key),
              Get(rabbitmq_configs),
              Get(rabbitmq_reconnect_timeout),
              Get(event_attempt_count),
              Get(error_from),
              Get(error_smtp)
             ],
    self() ! connect,
    {ok, #state{config = Config}}.

-spec get_config(atom(), #state{}) -> term().
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
-spec ack_event(#msgstate{}, #state{}) -> #state{}.
ack_event(#msgstate{tag = Tag}, #state{channel = {Channel, _}} = State) ->
    Ack = #'basic.ack'{delivery_tag = Tag},
    amqp_channel:call(Channel, Ack),
    State.

%% @doc Move the event to the retry queue
-spec queue_retry_event(#msgstate{}, #state{}) -> #state{}.
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
-spec reject_event(#msgstate{}, #state{}) -> #state{}.
reject_event(#msgstate{tag = Tag} = MsgState, State) ->
    lager:info("Stop retrying event (~p)", [Tag]),
    State1 = ack_event(MsgState, State),
    State2 = send_return(false, MsgState, State1),
    remove_event(MsgState, State2).

%% %% @doc Send a new message to the response queue.
%% -spec send_return(#msgstate{}, #state{}) -> #state{}.
%% send_return(#msgstate{payload = Payload, errors = Errors},
%%           #state{channel = {Channel, _}} = State) ->
send_return(Success, #msgstate{payload = Payload,
                               headers = OrgHeaders,
                               errors = Errors,
                               results = Results},
            #state{channel = {Channel, _}} = State0) ->
    lager:info("Sending return-event to message queue", []),
    AppResponse = get_config(rabbitmq_response, State0),
    Exchange = proplists:get_value(exchange, AppResponse),
    RoutingKey = proplists:get_value(routing_key, AppResponse),
    Publish = #'basic.publish'{exchange = Exchange, routing_key = RoutingKey},
    ResultHeader = [{<<"x-qpush-success">>, bool, Success},
                    {<<"x-qpush-errors">>, array,
                     lists:map(fun (E) ->
                                       {longstr, erlang:list_to_binary(io_lib:format("~p", [E]))}
                               end,
                               [Errors])}],
    Props = #'P_basic'{
               delivery_mode = 2,
               headers = OrgHeaders ++ ResultHeader
              },
    Msg = #amqp_msg{props = Props,
                    payload = case Success of
                                  true ->
                                      jiffy:encode(Results);
                                  false ->
                                      Payload
                              end},
    amqp_channel:cast(Channel, Publish, Msg),
    State0.

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
handle_info({worker_finished, {fail, Worker, Error}}, #state{} = State) ->
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
handle_info({worker_finished, {success, Worker, Result}}, #state{} = State) ->
    State1 = case get_worker_event(Worker, State) of
                 {ok, MsgState} ->
                     %% Event completed!
                     lager:info("Worker finished (~p)", [Worker]),
                     MsgState1 = add_result(MsgState, Result),
                     State2 = send_return(true, MsgState1, State),
                     State3 = ack_event(MsgState1, State2),
                     Worker ! stop,
                     retire_worker(Worker, State3);
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
            ok = setup_subscriptions(Channel, State),
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
                         payload = Payload,
                         headers = case AmqpHeaders of
                                       undefined -> [];
                                       _ -> AmqpHeaders
                                   end},
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
                {error, {Reason, Message}} ->
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

-spec create_worker(rabbitmq_tag(), qpusherl_event:event(), #state{}) -> {'ok', pid()}.
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

-spec setup_subscriptions(pid(), #state{}) -> 'ok'.
setup_subscriptions(Channel, State) ->
    AppWork = get_config(rabbitmq_work, State), % <<"queuepusherl">>
    AppResponse = get_config(rabbitmq_response, State),
    AppRetry = get_config(rabbitmq_retry, State),
    RoutingKey = get_config(rabbitmq_routing_key, State),

    WorkQueue = proplists:get_value(queue, AppWork),
    WorkExchange = proplists:get_value(exchange, AppWork),

    ResponseQueue = proplists:get_value(queue, AppResponse),
    ResponseExchange = proplists:get_value(exchange, AppResponse),
    ResponseKey = proplists:get_value(routing_key, AppResponse),

    RetryQueue = proplists:get_value(queue, AppRetry),
    RetryExchange = proplists:get_value(exchange, AppRetry),
    RetryTimeout = proplists:get_value(timeout, AppRetry),

    lager:info("Setting up subscription:~n"
               "Work queue: ~s @ ~s~n"
               "Response queue: ~s @ ~s~n"
               "Retry queue: ~s @ ~s", [WorkQueue, WorkExchange,
                                        ResponseQueue, ResponseExchange,
                                        RetryQueue, RetryExchange]),

    ok = setup_subscription(Channel, #subscription_info{queue = WorkQueue,
                                                        queue_durable = true,
                                                        exchange = WorkExchange,
                                                        exchange_durable = true,
                                                        dlx = RetryExchange,
                                                        routing_key = RoutingKey,
                                                        subscribe = true}),

    ok = setup_subscription(Channel, #subscription_info{queue = ResponseQueue,
                                                        queue_durable = true,
                                                        exchange = ResponseExchange,
                                                        exchange_durable = true,
                                                        routing_key = ResponseKey}),

    ok = setup_subscription(Channel, #subscription_info{queue = RetryQueue,
                                                        exchange = RetryExchange,
                                                        dlx = WorkExchange,
                                                        dlx_ttl = RetryTimeout,
                                                        routing_key = RoutingKey,
                                                        subscribe = false}),
    ok.


-spec setup_subscription(pid(), #subscription_info{}) -> 'ok' | {'error', Reason :: term()}.
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

-spec simplify_amqp_headers('undefined' | list()) -> map().
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

-spec amqp_headers_count_retries(map(), binary(), binary()) -> non_neg_integer().
amqp_headers_count_retries(#{<<"x-death">> := Deaths}, Queue, Reason) ->
    lists:foldl(fun (Death, PrevCount) ->
                        case Death of
                            #{<<"queue">> := Queue,
                              <<"reason">> := Reason,
                              <<"count">> := Count} -> Count;
                            _ -> PrevCount
                        end
                end, 0, Deaths);
amqp_headers_count_retries(_Headers, _Queue, _Reason) ->
    0.


%%% Functions for handling workers in state

%% @doc Add worker to the state
-spec store_worker(pid(), rabbitmq_tag(), #state{}) -> #state{}.
store_worker(Worker, Tag, #state{workers = Workers} = State) ->
    State#state{workers = maps:put(Worker, Tag, Workers)}.

%% @doc Remove worker from state
-spec remove_worker(pid(), #state{}) -> #state{}.
remove_worker(Worker, State = #state{workers = Workers}) ->
    State1 = case get_worker_event(Worker, State) of
                 {ok, MsgState} ->
                     remove_event(MsgState, State);
                 error ->
                     State
             end,
    State1#state{workers = maps:remove(Worker, Workers)}.

%% @doc Move worker from workers to oldworkers for it to wait for the worker process to terminate
-spec retire_worker(pid(), #state{}) -> #state{}.
retire_worker(Worker, #state{oldworkers = OldWorkers} = State) ->
    case is_worker(Worker, State) of
        true ->
            State1 = remove_worker(Worker, State),
            State1#state{oldworkers = sets:add_element(Worker, OldWorkers)};
        false ->
            State
    end.

-spec is_worker(pid(), #state{}) -> boolean.
is_worker(Worker, #state{workers = Workers}) ->
    maps:is_key(Worker, Workers).

-spec is_old_worker(pid(), #state{}) -> boolean.
is_old_worker(Worker, #state{oldworkers = OldWorkers}) ->
    sets:is_element(Worker, OldWorkers).

-spec clear_old_worker(pid(), #state{}) -> #state{}.
clear_old_worker(Worker, #state{oldworkers = OldWorkers} = State) ->
    State1 = remove_worker(Worker, State),
    State1#state{oldworkers = sets:del_element(Worker, OldWorkers)}.


%%% Functions for handling events in state

-spec get_event(non_neg_integer(), #state{}) -> {'ok', qpusherl_event:event()} | 'error'.
get_event(Tag, #state{events = Events}) ->
    maps:find(Tag, Events).

-spec get_worker_event(non_neg_integer(), #state{}) -> {'ok', qpusherl_event:event()} | 'error'.
get_worker_event(Worker, #state{workers = Workers} = State) ->
    case maps:find(Worker, Workers) of
        {ok, Tag} ->
            get_event(Tag, State);
        error ->
            error
    end.

-spec add_event(#msgstate{}, #state{}) -> #state{}.
add_event(#msgstate{tag = Tag} = MsgState, #state{events = Events} = State) ->
    State#state{events = maps:put(Tag, MsgState, Events)}.

-spec remove_event(#msgstate{}, #state{}) -> #state{}.
remove_event(#msgstate{tag = Tag}, State) ->
    remove_event(Tag, State);
remove_event(Tag, #state{events = Events} = State) ->
    State#state{events = maps:remove(Tag, Events)}.

-spec add_error(#msgstate{}, []) -> #msgstate{}.
add_error(#msgstate{errors = Errors} = MsgState, Error) ->
    MsgState#msgstate{errors = [Error|Errors]}.

add_result(#msgstate{results = Results} = MsgState, Result) ->
    MsgState#msgstate{results = [Result | Results]}.
