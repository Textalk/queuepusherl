-module(qpusherl_smtp_worker).
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

-record(state, {
          event           :: qpusherl_event:event(),
          retry_count = 0 :: non_neg_integer(),
          max_retries     :: non_neg_integer() | infinity,
          initial_delay   :: non_neg_integer(),
          errors = []     :: [binary()]
}).

%% API.

%-spec start_link(Event :: qpusherl_event:event()) -> {ok, pid()} | {error, term()}.
%start_link(Event) ->
-spec start_link(term()) -> {ok, pid()} | {error, term()}.
start_link(Event) ->
    ct:pal("Start link ~p~n", [Event]),
	gen_server:start_link(?MODULE, [Event], []).

%% gen_server.

init([Event]) ->
    ct:pal("Init worker! ~p", [Event]),
    State = #state{
               event = Event,
               max_retries = application:get_env(qpusherl, smtp_retry_count, 10),
               initial_delay = application:get_env(qpusherl, smtp_retry_initial_delay, 60000)
              },
    self() ! retry,
	{ok, State}.

handle_call(_Request, _From, _State) ->
    error(badarg).
	%{reply, ignored, State}.

handle_cast(_Msg, _State) ->
    error(badarg).
	%{noreply, State}.

make_mail_error(Name, Msg) ->
    BinMsg = case is_binary(Msg) of
                 true -> Msg;
                 false -> list_to_binary(io_lib:format("~p", [Msg]))
             end,
    BinName = atom_to_binary(Name, utf8),
    <<"{ ", BinName/binary, ": ", BinMsg/binary, " }">>.

handle_info(retry, State = #state{event = Event, errors = Errors}) ->
    Mail = qpusherl_smtp_event:get_mail(Event),
    Smtp = qpusherl_smtp_event:get_smtp_options(Event),
    case gen_smtp_client:send_blocking(Mail, Smtp) of
        Receipt when is_binary(Receipt) ->
            {stop, normal, State};
        {error, no_more_hosts, {permanent_failure, _Host, _Message}} ->
            send_error_mail(State),
            {stop, normal, State};
        {error, Type, Message} ->
            dispatch_retry(State#state{
                             errors = lists:append(Errors, make_mail_error(Type, Message))
                            });
        {error, Reason} ->
            dispatch_retry(State#state{
                             errors = lists:append(Errors, make_mail_error(unknown_error, Reason))
                            })
    end;
handle_info(Info, State) ->
    error_logger:info_msg("~p ignoring info ~p", [?MODULE, Info]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% -- internal --

dispatch_retry(State = #state{retry_count = RetryCount,
                              max_retries = MaxRetries,
                              initial_delay = InitialDelay})
  when RetryCount < MaxRetries ->
    erlang:send_after(InitialDelay bsl RetryCount, self(), retry),
    {noreply, State#state{retry_count = RetryCount + 1}, hibernate};
dispatch_retry(State = #state{retry_count = RetryCount,
                              max_retries = MaxRetries})
  when RetryCount >= MaxRetries ->
    send_error_mail(State),
    {stop, normal, State}.

send_error_mail(#state{event = Event, errors = Errors}) ->
    {ok, ErrorSmtp} = application:get_env(qpusherl, error_smtp),
    ErrorMail = qpusherl_event:build_error_mail(Event, Errors),
    case gen_smtp_client:send_blocking(ErrorMail, ErrorSmtp) of
        Receipt when is_binary(Receipt) ->
            ok;
        {error, Type, Message} ->
            error_logger:error_msg("Failed to send error mail: ~p ~p", [Type, Message]);
        {error, Reason} ->
            error_logger:error_msg("Failed to send error mail: ~p", [Reason])
    end.
