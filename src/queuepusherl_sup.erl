-module(queuepusherl_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
	supervisor:start_link({local, queuepusherl}, ?MODULE, []).

init([]) ->
    Procs = [
             {queuepusherl_smtp, % id 
              {queuepusherl_smtp_sup, start_link, []}, % start 
              permanent, % restart 
              5000, % shutdown 
              supervisor, % type 
              [queuepusherl_smtp_sup] % modules 
             },
             %{queuepusherl_http_sup, % id 
              %{queuepusher_http_sup, start_link, []}, % start 
              %permanent, % restart 
              %5000, % shutdown 
              %supervisor, % type 
              %[queuepusherl_http_sup] % modules 
             %},
             {queuepusherl_mq_listener, % id 
              {queuepusherl_mq_listener, start_link, []}, % start 
              permanent, % restart 
              5000, % shutdown 
              worker, % type 
              [queuepusherl_mq_listener] % modules 
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
