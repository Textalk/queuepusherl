-type mail()  :: {From :: binary(),
                  To :: [binary()],
                  Email :: binary()}.
-record(smtpoptions,
        {
         relay    :: binary(),
         port     :: non_neg_integer(),
         username :: binary(),
         password :: binary()
        }).
-type smtp() :: #smtpoptions{}.
-record(mailerror,
        {
         to      :: binary(),
         subject :: binary(),
         body    :: binary()
        }).
-type mailerror() :: #mailerror{}.
-record(mailevent,
        {
         mail  :: mail(),
         smtp  :: smtp(),
         error :: mailerror()
        }).
-type mailevent() :: #mailevent{}.
-record(httpevent,
        {
         topic :: binary(),
         data  :: map()
        }).
-type httpevent() :: #httpevent{}.
-type event() :: mailevent() | httpevent().
