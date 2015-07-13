-module(qpusherl_http_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([create_child/1]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	Procs = [],
	{ok, {{one_for_one, 1, 5}, Procs}}.

%% API functions, called outside of the process

create_child(Event) ->
    {ok, Pid} = supervisor:start_child(?MODULE, [Event]),
    monitor(process, Pid),
    {ok, Pid}.
