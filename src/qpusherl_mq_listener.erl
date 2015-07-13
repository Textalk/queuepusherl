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
-include("qpusherl_events.hrl").

-define(RECONNECT_TIMEOUT, 10000).
-define(SUBSCRIPTION_TIMEOUT, 10000).

-record(state, {
          connection           :: pid(),
          channel              :: pid(),
          workers = dict:new() :: dict:dict(pid(), {integer(), term()})
         }).

%% API.

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    io:format("Starting mq listener", []),
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% gen_server.

init([]) ->
    io:format("Init mq", []),
    self() ! connect,
	{ok, #state{}}.

handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

-spec create_worker({atom(), term()}) -> {'ok', pid()}.
create_worker({smtp, _Event}) ->
    %qpusherl_smtp_sup:create_child(Event);
    ok;
create_worker({http, _Event}) ->
    %qpusherl_http_sup:create_child(Event).
    ok.

% @doc Handle incoming messages from system and RabbitMQ.
handle_info({'DOWN', _MRef, process, Worker, Reason},
            #state{workers = Workers} = State0) ->
    % When a worker is done we ACK the message.
    {Tag, Event} = dict:fetch(Worker, Workers),
    State1 = State0#state{workers = dict:erase(Worker, Workers)},
    case Reason of
        normal ->
            send_ack(Tag, State1),
            {noreply, State1};
        _ ->
            error_logger:error_msg("Could not push message, process failed:~n"
                                   "Event: ~p~n", [Event]),
            {noreply, State1}
    end;
handle_info(connect, #state{connection = undefined} = State) ->
    % Setup connection to RabbitMQ and connect.
    {ok, RabbitConfigs} = application:get_env(qpusherl, rabbitmq_configs),
    io:format("Connect~n"),
    case connect(RabbitConfigs) of
        {ok, Connection} ->
            link(Connection),
            {ok, Channel} = amqp_connection:open_channel(Connection),
            link(Channel),
            ok = setup_subscription(Channel),
            {noreply, State#state{connection = Connection, channel = Channel}};
        {error, no_connection_to_mq} ->
            erlang:send_after(?RECONNECT_TIMEOUT, self(), connect),
            {noreply, State}
    end;
handle_info({#'basic.deliver'{delivery_tag = Tag}, #amqp_msg{payload = Payload}},
            #state{workers = Workers0} = State) ->
    io:format("Getting message: ~p", [Payload]),
    % Handles incoming messages from RabbitMQ.
    case qpusherl_event:parse(Payload) of
        {ok, Event} ->
            {ok, Pid} = create_worker(Event),
            Workers1 = dict:store(Pid, {Tag, Event}, Workers0),
            {noreply, State#state{workers = Workers1}};
        {error, Reason, _} ->
            error_logger:error_msg("Invalid qpusherl message:~n"
                                   "Payload: ~p~n"
                                   "Reason: ~p~n"
                                   "Trace: ~p~n",
                                   [Payload, Reason, erlang:get_stacktrace()]),
            send_ack(Tag, State),
            {noreply, State}
    end;
handle_info(#'basic.cancel'{}, State) ->
    % Handles RabbitMQ going down. Nothing to worry about, just crash and restart.
    {stop, subscription_canceled, State};
handle_info(Info, State) ->
    % Some other message to the server pid.
    error_logger:info_msg("~p ignoring info ~p", [?MODULE, Info]),
	{noreply, State}.

terminate(_Reason, #state{connection = Connection, channel = Channel}) ->
    io:format("Shutdown message queue processor", []),
    catch amqp_channel:close(Channel),
    catch amqp_connection:close(Connection),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

send_ack(Tag, #state{channel = Channel}) ->
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
    io:format("Trying to connect: ~p", [AmqpConnParams]),
    case amqp_connection:start(AmqpConnParams) of
        {ok, Connection} ->
            {ok, Connection};
        {error, Reason} ->
            error_logger:warning_msg("Unable to connect to RabbitMQ broker"
                                     " for reason ~p using config ~p.",
                                     [Reason, MQParams]),
            connect(Rest)
    end;
connect([]) ->
    error_logger:error_msg("Failed to connect to all RabbitMQ brokers."),
    {error, no_connection_to_mq}.

setup_subscription(ChannelPid) ->
    %% Queue settings
    {ok, Queue}    = application:get_env(qpusherl, rabbitmq_queue),
    {ok, Exchange} = application:get_env(qpusherl, rabbitmq_exchange),

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
