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

-record(state, {
          connection        :: {pid(), term()} | undefined,
          channel           :: {pid(), term()} | undefined,
          tags = sets:new() :: sets:set(integer())
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

terminate(Reason, #state{connection = {Connection, _}, channel = {Channel, _}}) ->
    lager:warning("Message queue listener stopped: ~p~n", [Reason]),
    catch amqp_channel:close(Channel),
    catch amqp_connection:close(Connection),
    ok.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

-spec create_worker(integer(), {atom(), term()}) -> {'ok', pid()}.
create_worker(Tag, {smtp, Event}) ->
    qpusherl_smtp_sup:create_child(self(), Tag, Event);
create_worker(_Tag, {http, _Event}) ->
    %qpusherl_http_sup:create_child(self(), Tag, Event).
    {ok, no_pid}.

% @doc Handle incoming messages from system and RabbitMQ.
handle_info({'DOWN', MRef, process, _Worker, Reason},
            #state{connection = {_, ConM}, channel = {_, ChanM}} = State) when
      MRef == ConM; MRef == ChanM ->
    lager:error("RabbitMQ connection or channel is down: ~p~n", [Reason]),
    {stop, rabbitmq_down, State#state{connection = undefined, channel = undefined}};
handle_info({mail_sent, Tag}, State = #state{tags = Tags}) ->
    send_ack(Tag, State),
    lager:info("Mail event has been acked!"),
    State1 = State#state{tags = sets:del_element(Tag, Tags)},
    {noreply, State1};
handle_info(connect, #state{connection = undefined} = State) ->
    % Setup connection to RabbitMQ and connect.
    {ok, RabbitConfigs} = application:get_env(queuepusherl, rabbitmq_configs),
    lager:info("Connecting to RabbitMQ"),
    case connect(RabbitConfigs) of
        {ok, Connection} ->
            ConM = monitor(process, Connection),
            {ok, Channel} = amqp_connection:open_channel(Connection),
            ChanM = monitor(process, Channel),
            ok = setup_subscription(Channel),
            lager:info("Established connection to RabbitMQ"),
            {noreply, State#state{connection = {Connection, ConM}, channel = {Channel, ChanM}}};
        {error, no_connection_to_mq} ->
            erlang:send_after(?RECONNECT_TIMEOUT, self(), connect),
            {noreply, State}
    end;
handle_info({#'basic.deliver'{delivery_tag = Tag}, #amqp_msg{payload = Payload}},
            #state{tags = Tags} = State) ->
    lager:debug("Getting message: ~p~n", [non]),
    % Handles incoming messages from RabbitMQ.
    case qpusherl_event:parse(Payload) of
        {ok, Event} ->
            {ok, _Pid} = create_worker(Tag, Event),
            {noreply, State#state{tags = sets:add_element(Tag, Tags)}};
        {error, Reason, _} ->
            lager:error("Invalid qpusherl message:~n"
                        "Payload: ~p~n"
                        "Reason: ~p~n"
                        "Trace: ~p~n",
                        [Payload, Reason, erlang:get_stacktrace()]),
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

setup_subscription(ChannelPid) ->
    %% Queue settings
    {ok, Queue}    = application:get_env(queuepusherl, rabbitmq_queue),
    {ok, Exchange} = application:get_env(queuepusherl, rabbitmq_exchange),

    %% We use the same name for the routing key as the queue name
    RoutingKey = Queue,

    %% Declare the queue
    QueueDeclare = #'queue.declare'{queue = Queue, durable = true},
    #'queue.declare_ok'{} = amqp_channel:call(ChannelPid, QueueDeclare),

    %% Bind the queue to the exchange
    Binding = #'queue.bind'{queue = Queue, exchange = Exchange,
                            routing_key = RoutingKey},
    #'queue.bind_ok'{} = amqp_channel:call(ChannelPid, Binding),

    %% Setup the subscription
    Subscription = #'basic.consume'{queue = Queue},
    #'basic.consume_ok'{consumer_tag = Tag} =
    amqp_channel:subscribe(ChannelPid, Subscription, self()),
    receive
        #'basic.consume_ok'{consumer_tag = Tag} -> ok
    after
        ?SUBSCRIPTION_TIMEOUT -> {error, timeout}
    end.
