-module(queuepusherl_smtp_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([create_child/1]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Procs = [
             {queuepusherl_smtp_worker, % id
              {queuepusherl_smtp_worker, start_link, []}, % start
              transient, % restart
              5000, % shutdown
              worker, % type
              [queuepusherl_smtp_worker] % modules
             }
            ],
    {ok, {{simple_one_for_one, % strategy
           1, % intensity
           10 % period
          },
          Procs
         }
    }.

%% API functions, called outside of the process

create_child(Event) ->
    {ok, Pid} = supervisor:start_child(?MODULE, [Event]),
    monitor(process, Pid),
    {ok, Pid}.
