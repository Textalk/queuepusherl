-module(qpusherl_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
	supervisor:start_link({local, qpusherl}, ?MODULE, []).

init([]) ->
    lager:info("Queuepusherl supervisor started!"),
    Procs = [
             {qpusherl_mq_listener,                   % id 
              {qpusherl_mq_listener, start_link, []}, % start 
              permanent,                              % restart 
              5000,                                   % shutdown 
              worker,                                 % type 
              [qpusherl_mq_listener]                  % modules 
             },
             {qpusherl_event,
              {qpusherl_worker_sup, start_link, []},
              permanent,
              5000,
              supervisor,
              [qpusherl_worker_sup]
             }
            ],
    {ok, {
       {one_for_all, % strategy
        10,          % intensity
        10           % period
       },
       Procs
      }
    }.
