-module(qpusherl_smtp_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([create_child/2]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    lager:info("SMTP supervisor started!"),
    Procs = [
             {qpusherl_smtp_worker,  % id
              {qpusherl_smtp_worker, start_link, []}, % start
              %% Use 'temporary' instead of 'transient' since we need to be able to handle workers
              %% that die and take care of restarting it ourselves.
              temporary,             % restart policy
              5000,                  % shutdown
              worker,                % type
              [qpusherl_smtp_worker] % modules
             }
            ],
    {ok, {{simple_one_for_one, % strategy
           1, % intensity
           5  % period
          },
          Procs
         }
    }.

%% API functions, called outside of the process

-spec create_child(pid(), qpusherl_smtp_event:smtp_event()) -> {'ok', pid()}.
create_child(Owner, Event) ->
    supervisor:start_child(?MODULE, [[Owner, Event]]).
