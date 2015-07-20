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
          owner           :: pid(),
          event           :: qpusherl_event:event(),
          retry_count = 0 :: non_neg_integer(),
          max_retries     :: non_neg_integer() | infinity,
          initial_delay   :: non_neg_integer(),
          errors = []     :: [binary()]
}).

%% API.

%-spec start_link(Event :: qpusherl_event:event()) -> {ok, pid()} | {error, term()}.
%start_link(Event) ->
-spec start_link([term()]) -> {ok, pid()} | {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% gen_server.

init([Owner, Event]) ->
    lager:info("SMTP worker started! (~p)", [self()]),
    State = #state{
               owner = Owner,
               event = Event,
               max_retries = application:get_env(queuepusherl, smtp_retry_count, 10),
               initial_delay = application:get_env(queuepusherl, smtp_retry_initial_delay, 60000)
              },
    %% Do not send retry, let the starting process do that so that it has time to monitor the
    %% process first.
    %self() ! retry,
    {ok, State}.

handle_call(_Request, _From, _State) ->
    error(badarg).
	%{reply, ignored, State}.

handle_cast(_Msg, _State) ->
    error(badarg).
	%{noreply, State}.

%make_mail_error(Name, Msg) ->
    %BinMsg = case is_binary(Msg) of
                 %true -> Msg;
                 %false -> list_to_binary(io_lib:format("~p", [Msg]))
             %end,
    %BinName = atom_to_binary(Name, utf8),
    %<<"{ ", BinName/binary, ": ", BinMsg/binary, " }">>.

handle_info(retry, State = #state{owner = Owner}) ->
    lager:info("Trying to send mail (~p)", [self()]),
    case send_mail(State) of
        {done, State1} ->
            Owner ! {event_finished, self()},
            lager:info("Mail sent! (~p)", [self()]),
            {stop, normal, State1};
        {retry, State1} ->
            dispatch_retry(State1)
    end;
handle_info(Info, State) ->
    lager:info("~p (~p) ignoring info ~p", [?MODULE, self(), Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    lager:info("Terminating SMTP worker! (~p)", [self()]),
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

send_mail(State = #state{event = Event}) ->
    Mail = qpusherl_smtp_event:get_mail(Event),
    Smtp = qpusherl_smtp_event:get_smtp_options(Event),
    lager:debug("send_mail(~p = #state{event = ~p})~nMail: ~p~nSmtp: ~p~n", [State, Event, Mail,
                                                                           Smtp]),
    {A, B, C} = erlang:now(),
    N = (A + B + C) rem 3,
    case N of
        N when N =< 0 -> exit({no_reason, "Just don't feel like it!"});
        N -> timer:send_after(timer:seconds(3), timeout),
             receive timeout -> ok end,
             {done, State}
    end.
    %case gen_smtp_client:send_blocking(Mail, Smtp) of
        %Receipt when is_binary(Receipt) ->
            %{done, State};
        %{error, no_more_hosts, {permanent_failure, _Host, _Message}} ->
            %send_error_mail(State),
            %{done, State};
        %{error, Type, Message} ->
            %Event1 = qpusherl_smtp_event:add_error(Event, make_mail_error(Type, Message)),
            %{retry, State#state{event = Event1}};
        %{error, Reason} ->
            %Event1 = qpusherl_smtp_event:add_error(Event, make_mail_error(unknown_error, Reason)),
            %{retry, State#state{event = Event1}}
    %end.

send_error_mail(#state{event = Event}) ->
    {ok, ErrorSmtp} = application:get_env(queuepusherl, error_smtp),
    ErrorMail = qpusherl_event:get_error_mail(Event),
    lager:debug("send_error_mail(#state{event = ~p})~nErrorMail: ~p~nErrorSmtp: ~p~n", [Event,
                                                                                      ErrorMail,
                                                                                      ErrorSmtp]).
    %case gen_smtp_client:send_blocking(ErrorMail, ErrorSmtp) of
        %Receipt when is_binary(Receipt) ->
            %ok;
        %{error, Type, Message} ->
            %error_logger:error_msg("Failed to send error mail: ~p ~p", [Type, Message]);
        %{error, Reason} ->
            %error_logger:error_msg("Failed to send error mail: ~p", [Reason])
    %end.
