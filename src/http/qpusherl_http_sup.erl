-module(qpusherl_http_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([create_child/2]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    lager:info("HTTP supervisor started!"),
    Procs = [
             {qpusherl_http_worker,
              {qpusherl_http_worker, start_link, []},
              temporary,             % restart policy
              5000,                  % shutdown
              worker,                % type
              [qpusherl_http_worker] % modules
             }
            ],
    {ok, {{simple_one_for_one, % strategy
           1,                  % intensity
           5                   % period
          },
          Procs
         }
    }.

%% API functions, called outside of the process

-spec create_child(pid(), qpusherl_http_event:http_event()) -> {'ok', pid()}.
create_child(Owner, Event) ->
    supervisor:start_child(?MODULE, [[Owner, Event]]).
