-module(qpusherl_http_worker).
-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
          owner           :: pid(),
          event           :: qpusherl_event:event(),
          retry_count = 0 :: non_neg_integer(),
          max_retries     :: non_neg_integer() | infinity,
          initial_delay   :: non_neg_integer()
         }).

%% API.

%-spec start_link(Event :: qpusherl_event:event()) -> {ok, pid()} | {error, term()}.
%start_link(Event) ->
-spec start_link([term()]) -> {ok, pid()} | {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% gen_server.

init([Owner, Event]) ->
    State = #state{owner = Owner,
                   event = Event},
    {ok, State}.

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Msg, _State) ->
    error(badarg).

handle_info(retry, State = #state{owner = Owner}) ->
    lager:info("Trying to do http request (~p)", [self()]),
    case do_request(State) of
        {done, State1} ->
            Owner ! {event_finished, self()},
            lager:info("Request completed! (~p)", [self()]),
            {stop, normal, State1};
        {retry, State1} ->
            dispatch_retry(State1)
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

do_request(State = #state{event = Event}) ->
    case qpusherl_http_event:get_request(Event) of
        #{url := Url,
          data := Data,
          query := Query} ->
            lager:notice("Do request: ~p ~p ~p", [Url, Data, Query]),
            {done, State};
        _ ->
            State1 = qpusherl_http_event:add_error(
                       State, {invalid_request, <<"Request could not be understood">>}),
            lager:error("Invalid request: ~p", [Event]),
            {done, State1}
    end.

dispatch_retry(State = #state{retry_count = RetryCount,
                              max_retries = MaxRetries,
                              initial_delay = InitialDelay})
  when RetryCount < MaxRetries ->
    erlang:send_after(InitialDelay bsl RetryCount, self(), retry),
    {noreply, State#state{retry_count = RetryCount + 1}, hibernate};
dispatch_retry(State = #state{retry_count = RetryCount,
                              max_retries = MaxRetries})
  when RetryCount >= MaxRetries ->
    %% TODO do some error response
    lager:notice("HTTP Request failed", []),
    {stop, normal, State}.
