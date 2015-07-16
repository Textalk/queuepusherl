-module(qpusherl_smtp_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([create_child/3]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    lager:info("SMTP supervisor started!"),
    Procs = [
             {qpusherl_smtp_worker, % id
              {qpusherl_smtp_worker, start_link, []}, % start
              transient, % restart
              5000, % shutdown
              worker, % type
              [qpusherl_smtp_worker] % modules
             }
            ],
    {ok, {{simple_one_for_one, % strategy
           3, % intensity
           10 % period
          },
          Procs
         }
    }.

%% API functions, called outside of the process

-spec create_child(pid(), integer(), qpusherl_smtp_event:smtp_event()) -> {'ok', pid()}.
create_child(Owner, Tag, Event) ->
    supervisor:start_child(?MODULE, [[Owner, Tag, Event]]).
