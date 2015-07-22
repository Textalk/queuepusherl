-module(qpusherl_worker_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([create_child/2]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    lager:info("Event worker supervisor started!"),
    Procs = [
             {qpusherl_event_worker,
              {qpusherl_event_worker, start_link, []},
              temporary,
              5000,
              worker,
              [qpusherl_event_worker]
             }
            ],
    {ok, {{simple_one_for_one, % strategy
           1,                  % restart intensity
           5                   % restart period
          },
          Procs
         }
    }.

%% API functions, called outside of the process

-spec create_child(pid(), qpusherl_http_event:http_event()) -> {'ok', pid()}.
create_child(Owner, Event) ->
    supervisor:start_child(?MODULE, [[Owner, Event]]).
