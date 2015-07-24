-module(qpusherl_event_worker).
-behaviour(gen_server).

%% API.
-export([start_link/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(EVENT_TYPES, #{
          smtp => qpusherl_smtp_worker,
          http => qpusherl_http_worker
         }).

-record(state, {
          event  :: term(),
          owner  :: pid(),
          callback :: atom(),
          retry_count = 0,
          max_retries,
          initial_delay
}).

-type state() :: #state{}.

%-spec start_link(Event :: qpusherl_event:event()) -> {ok, pid()} | {error, term()}.
%start_link(Event) ->
-spec start_link([term()]) -> {ok, pid()} | {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% gen_server.

init([Owner, {Tag, Event}]) ->
    lager:info("Event worker started! (~p)", [self()]),
    Callback = case maps:find(Tag, ?EVENT_TYPES) of
                   {ok, Module} -> Module;
                   _ -> throw({invalid_event, <<"Unknown event type">>})
               end,
    Retry = get_tagged_config(event_retry_count, Tag, 10),
    Delay = get_tagged_config(event_initial_delay, Tag, 60000),
    State = #state{
               event = Event,
               owner = Owner,
               callback = Callback,
               max_retries = Retry,
               initial_delay = Delay
              },
    {ok, State}.

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Msg, _State) ->
    error(badarg).

handle_info(retry, State = #state{owner = Owner}) ->
    lager:info("Trying to execute event (~p)", [self()]),
    case execute_event(State) of
        {done, State1} ->
            Owner ! {worker_finished, self()},
            lager:info("Event completed! (~p)", [self()]),
            {stop, normal, State1};
        {retry, State1} ->
            delay_event_retry(State1)
    end;
handle_info(Info, _State) ->
    error({badarg, Info}).

terminate(_Reason, _State) ->
    lager:info("Event worker terminated! (~p)", [self()]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

delay_event_retry(State = #state{retry_count = RetryCount,
                                 max_retries = MaxRetries,
                                 initial_delay = InitialDelay})
  when RetryCount < MaxRetries ->
    lager:notice("~p retries left for event worker (~p)", [MaxRetries - RetryCount, self()]),
    erlang:send_after(InitialDelay bsl RetryCount, self(), retry),
    {noreply, State#state{retry_count = RetryCount + 1}, hibernate};
delay_event_retry(State = #state{retry_count = RetryCount,
                                 max_retries = MaxRetries})
  when RetryCount >= MaxRetries ->
    fail_event(State),
    {stop, normal, State}.

-spec execute_event(state()) -> {'done' | 'retry', state()}.
execute_event(#state{event = Event, callback = Callback} = State) ->
    case Callback:process_event(Event) of
        ok ->
            {done, State};
        {error, Reason, Description} ->
            Event1 = qpusherl_event:add_error(Event, {Reason, Description}),
            lager:warning("Request failed, scheduling retry: ~p", [Reason]),
            {retry, State#state{event = Event1}}
    end.

-spec fail_event(state()) -> ok.
fail_event(#state{event = Event, callback = Callback}) ->
    Callback:fail_event(Event).

-spec get_tagged_config(atom(), atom(), binary() | atom()) -> term().
get_tagged_config(ValueName, Tag, Default) ->
    case application:get_env(queuepusherl, Tag, undefined) of
        undefined ->
            Default;
        List ->
            case lists:keyfind(ValueName, 1, List) of
                {_, Value} -> Value;
                _ -> Default
            end
    end.

