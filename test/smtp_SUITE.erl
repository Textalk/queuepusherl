-module(smtp_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../deps/amqp_client/include/amqp_client.hrl").

-export([parse/1]).
-export([parse_multipart/1]).
-export([simple_mail_1/1]).
-export([simple_mail_2/1]).
-export([parts_mail_1/1]).
-export([utf8_mail_1/1]).
-export([utf8_mail_2/1]).

-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

-define(RAW_MAIL_EVENT,
        #{<<"mail">> => #{
              <<"from">> => <<"Admin <admin@localhost>">>,
              <<"to">> => [<<"foo@example.com">>],
              <<"extra-headers">> => #{},
              <<"body">> => <<"This is a mail">>},
          <<"smtp">> => #{
              <<"relay">> => <<"smtp.localdomain">>,
              <<"port">> => 25,
              <<"username">> => <<"username">>,
              <<"password">> => <<"password">>
             },
          <<"error">> => #{
              <<"to">> => <<"Email <user@localhost>">>,
              <<"subject">> => <<"An error e-mail">>,
              <<"body">> => <<"Further e-mail information">>
             }}).
-define(RAW_MULTIPART_MAIL_EVENT,
        #{<<"mail">> => #{
              <<"from">> => <<"Admin <admin@localhost>">>,
              <<"to">> => [<<"foo@example.com">>],
              <<"extra-headers">> => #{},
              <<"body">> => [#{<<"headers">> => #{},
                               <<"body">> => <<"This is a mail">>}]},
          <<"smtp">> => #{
              <<"relay">> => <<"smtp.localdomain">>,
              <<"port">> => 25,
              <<"username">> => <<"username">>,
              <<"password">> => <<"password">>
             },
          <<"error">> => #{
              <<"to">> => <<"Email <user@localhost>">>,
              <<"subject">> => <<"An error e-mail">>,
              <<"body">> => <<"Further e-mail information">>
             }}).
-define(DEFAULT_PARSE_OPTS, [{error_from, <<"admin@no.host">>}]).

all() ->
    [
     simple_mail_1,
     simple_mail_2,
     utf8_mail_1,
     utf8_mail_2,
     parts_mail_1,
     parse,
     parse_multipart
    ].

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

parse(_Config) ->
    {ok, SmtpEvent} = qpusherl_smtp_event:parse(?RAW_MAIL_EVENT, ?DEFAULT_PARSE_OPTS),
    ?assertMatch({smtp_event,
                  {mail,
                   <<"<admin@localhost>">>,
                   [<<"<foo@example.com>">>],
                   _},
                  [{smtp,
                    <<"smtp.localdomain">>,
                    25,
                    <<"username">>,
                    <<"password">>}],
                  {mailerror,
                   <<"Email <user@localhost>">>,
                   <<"admin@no.host">>,
                   <<"An error e-mail">>,
                   _,
                   _}
                 }, SmtpEvent),
    ?assertMatch({<<"<admin@localhost>">>, [<<"<foo@example.com>">>], _Mail}, qpusherl_smtp_event:get_mail(SmtpEvent)),
    ?assertMatch({_FromMail, _ToAddress, _Mail}, qpusherl_smtp_event:get_error_mail(SmtpEvent, [])),
    ?assertMatch([[{relay, _}, {port, _}, {username, _}, {password, _}]],
                 qpusherl_smtp_event:get_smtp_options(SmtpEvent)),
    ok.

parse_multipart(_Config) ->
    {ok, SmtpEvent} = qpusherl_smtp_event:parse(?RAW_MULTIPART_MAIL_EVENT,
                                                ?DEFAULT_PARSE_OPTS),
    {smtp_event, {mail, _To, _From, MailBody}, _SMTP, _ERROR} = SmtpEvent,
    Mail = clean_up_mail(MailBody),
    ExpectedMail = <<"From: Admin <admin@localhost>\r\n"
                   "To: foo@example.com\r\nDate: _\r\n"
                   "Content-Type: multipart/mixed;\r\n\tboundary=\"_1_\"\r\n"
                   "MIME-Version: 1.0\r\n"
                   "Message-ID: _\r\n"
                   "\r\n"
                   "\r\n"
                   "--_1_\r\n"
                   "Content-Type: text/plain;\r\n\tcharset=utf-8\r\n"
                   "Content-Disposition: inline\r\n"
                   "\r\n"
                   "This is a mail\r\n"
                   "--_1_--\r\n">>,
    ?assertEqual(isolate_difference(Mail, ExpectedMail), {<<>>, <<>>}),
    ok.

simple_mail_1(_Config) ->
    TestMail = #{
      <<"mail">> => #{
          <<"from">>          => <<"A B <a.b@c.se>">>,
          <<"to">>            => [<<"z.u@d.se">>,
                                  <<"Y V <y.v@d.se>">>],
          <<"cc">>            => [<<"q.r@d.se">>],
          <<"extra-headers">> => #{},
          <<"body">>          => []
         },
      <<"smtp">> => #{
          <<"relay">>    => <<"smtp.nowhere.test">>,
          <<"port">>     => 25,
          <<"username">> => <<"nobody">>,
          <<"password">> => <<"secret">>
         },
      <<"error">> => #{
          <<"to">>      => <<"<admin@c.se>">>,
          <<"subject">> => <<"This is a subject">>,
          <<"body">>    => <<"This is a message">>
         }
     },
    {ok, {smtp_event,
          {mail, From, To, Mail},
          [{smtp, SMTPRelay, _Port, _Username, _Password}],
          {mailerror, ErrorTo, _ErrorFrom, ErrorSubject, ErrorMsg, undefined}
         }
    } = qpusherl_smtp_event:parse(TestMail, ?DEFAULT_PARSE_OPTS),
    ?assertEqual(From, <<"<a.b@c.se>">>),
    ?assertEqual(lists:sort(To), lists:sort([<<"<z.u@d.se>">>,
                                             <<"<y.v@d.se>">>,
                                             <<"<q.r@d.se>">>])),
    ?assertEqual(SMTPRelay, <<"smtp.nowhere.test">>),
    ?assertEqual(ErrorTo, <<"<admin@c.se>">>),
    ?assertEqual(ErrorSubject, <<"This is a subject">>),
    ?assertEqual(ErrorMsg, <<"This is a message">>),

    Mail2 = clean_up_mail(Mail),

    ExpectedMail = <<"From: A B <a.b@c.se>\r\n"
                     "To: z.u@d.se, Y V <y.v@d.se>\r\n"
                     "Cc: q.r@d.se\r\n"
                     "Date: _\r\n"
                     "Content-Type: multipart/mixed;\r\n"
                     "\tboundary=\"_1_\"\r\n"
                     "MIME-Version: 1.0\r\n"
                     "Message-ID: _\r\n"
                     "\r\n"
                     "\r\n"
                     "--_1_--\r\n">>,
    ?assertEqual(isolate_difference(Mail2, ExpectedMail), {<<>>, <<>>}),
    ok.

simple_mail_2(_Config) ->
    TestMail = #{
      <<"mail">> => #{
          <<"from">>          => <<"A B <a.b@c.se>">>,
          <<"to">>            => [<<"z.u@d.se">>,
                                  <<"Y V <y.v@d.se>">>],
          <<"cc">>            => [<<"q.r@d.se">>],
          <<"subject">>       => <<"Subject">>,
          <<"extra-headers">> => #{},
          <<"body">>          => <<"Not empty">>
         },
      <<"smtp">> => #{
          <<"relay">>    => <<"smtp.nowhere.test">>,
          <<"port">>     => 25,
          <<"username">> => <<"nobody">>,
          <<"password">> => <<"secret">>
         },
      <<"error">> => #{
          <<"to">>      => <<"<admin@c.se>">>,
          <<"subject">> => <<"This is a subject">>,
          <<"body">>    => <<"This is a message">>
         }
     },

    {ok,
     {smtp_event, {mail, _From, _To, Mail}, _SMTP, _ErrorInfo}
    } = qpusherl_smtp_event:parse(TestMail, ?DEFAULT_PARSE_OPTS),

    Mail1 = clean_up_mail(Mail),

    ExpectedMail = <<"From: A B <a.b@c.se>\r\n"
                     "To: z.u@d.se, Y V <y.v@d.se>\r\n"
                     "Cc: q.r@d.se\r\n"
                     "Subject: Subject\r\n"
                     "Date: _\r\n"
                     "MIME-Version: 1.0\r\n"
                     "Message-ID: _\r\n"
                     "\r\n"
                     "Not empty">>,
    ?assertEqual(isolate_difference(Mail1, ExpectedMail), {<<>>, <<>>}),
    ok.

%% @doc This tests short mails with embeded UTF-8 characters, these will be base64 encoded.
%% @end
utf8_mail_1(_Config) ->
    TestMail = #{
      <<"mail">> => #{
          <<"from">>          => <<"A B <a.b@c.se>">>,
          <<"to">>            => [<<"z.u@d.se">>,
                                  <<"Y V <y.v@d.se>">>],
          <<"cc">>            => [<<"q.r@d.se">>],
          <<"extra-headers">> => #{},
          <<"body">>          => <<"Räksmörgås"/utf8>>
         },
      <<"smtp">> => #{
          <<"relay">>    => <<"smtp.nowhere.test">>,
          <<"port">>     => 25,
          <<"username">> => <<"nobody">>,
          <<"password">> => <<"secret">>
         },
      <<"error">> => #{
          <<"to">>      => <<"<admin@c.se>">>,
          <<"subject">> => <<"This is a subject">>,
          <<"body">>    => <<"This is a message">>
         }
     },
    Base64Body = list_to_binary(base64:encode_to_string(<<"Räksmörgås"/utf8>>)),
    {ok, {
       smtp_event, {mail, _From, _To, Mail}, _SMTP, _ERROR}
    } = qpusherl_smtp_event:parse(TestMail, ?DEFAULT_PARSE_OPTS),

    Mail2 = clean_up_mail(Mail),

    ExpectedMail = <<"From: A B <a.b@c.se>\r\n"
                     "To: z.u@d.se, Y V <y.v@d.se>\r\n"
                     "Cc: q.r@d.se\r\n"
                     "Date: _\r\n"
                     "Content-Type: text/plain;\r\n"
                     "\tcharset=utf-8\r\n"
                     "Content-Transfer-Encoding: base64\r\n"
                     "MIME-Version: 1.0\r\n"
                     "Message-ID: _\r\n"
                     "\r\n",
                     Base64Body/binary, "\r\n">>,
    {Diff1, Diff2} = isolate_difference(Mail2, ExpectedMail),
    ?assertEqual(Diff1, Diff2),
    ok.

%% @doc This tests long mails with embeded UTF-8 characters, these will be "quoted-printable"
%% encoded.
%% @end
utf8_mail_2(_Config) ->
    %% The body strings in the following mail is made long so that the library used to make e-mail
    %% formatted strings doesn't base64 encode them. (They will be transfer encoded with
    %% "quoted-printable" instead.
    TestMail = #{
      <<"mail">> => #{
          <<"from">>          => <<"A B <a.b@c.se>">>,
          <<"to">>            => [<<"z.u@d.se">>,
                                  <<"Y V <y.v@d.se>">>],
          <<"cc">>            => [<<"q.r@d.se">>],
          <<"subject">>       => <<"Here we have a rather long subject containing åÅö"/utf8>>,
          <<"content-type">>  => <<"multipart/alternative">>,
          <<"extra-headers">> => #{ },
          <<"body">>          => [
                                  #{<<"headers">> => #{
                                        <<"content-type">> => <<"text/plain">>
                                       },
                                    <<"body">> => <<"This text is not to be base64 encoded, "/utf8,
                                                    "it is long enough not to, Räksmörgås"/utf8>>
                                   },
                                  #{<<"headers">> => #{
                                        <<"content-type">> => <<"text/html">>
                                       },
                                    <<"body">> => <<"<html><head><title></title></head><body>"/utf8,
                                                    "<b>Räksmörgås</b></body></html>"/utf8>>
                                   }
                                 ]
         },
      <<"smtp">> => #{
          <<"relay">>    => <<"smtp.nowhere.test">>,
          <<"port">>     => 25,
          <<"username">> => <<"nobody">>,
          <<"password">> => <<"secret">>
         },
      <<"error">> => #{
          <<"to">>      => <<"<admin@c.se>">>,
          <<"subject">> => <<"This is a subject">>,
          <<"body">>    => <<"This is a message">>
         }
     },
    {ok,
     {smtp_event, {mail, _From, _To, Mail}, _SMTP, _ERROR}
    } = qpusherl_smtp_event:parse(TestMail, ?DEFAULT_PARSE_OPTS),

    Mail2 = clean_up_mail(Mail),

    ExpectedMail = <<"From: A B <a.b@c.se>\r\n"
                     "To: z.u@d.se, Y V <y.v@d.se>\r\n"
                     "Cc: q.r@d.se\r\n"
                     "Subject: =?UTF-8?Q?Here=20we=20have=20a=20rather=20"
                     "long=20subject=20contai?=\r\n =?UTF-8?Q?ning=20=C3=A5=C3=85=C3=B6?=\r\n"
                     "Date: _\r\n"
                     "Content-Type: multipart/alternative;\r\n"
                     "\tboundary=\"_1_\"\r\n"
                     "MIME-Version: 1.0\r\n"
                     "Message-ID: _\r\n"
                     "\r\n"
                     "\r\n"
                     "--_1_\r\n"
                     "Content-Type: text/plain;\r\n"
                     "\tcharset=utf-8\r\n"
                     "Content-Disposition: inline\r\n"
                     "Content-Transfer-Encoding: quoted-printable\r\n"
                     "\r\n"
                     "This text is not to be base64 encoded, it is long enough not to, =\r\n"
                     "R=C3=A4ksm=C3=B6rg=C3=A5s\r\n"
                     "--_1_\r\n"
                     "Content-Type: text/html;\r\n"
                     "\tcharset=utf-8\r\n"
                     "Content-Disposition: inline\r\n"
                     "Content-Transfer-Encoding: quoted-printable\r\n"
                     "\r\n"
                     "<html><head><title></title></head><body><b>R=C3=A4ksm=C3=B6rg=C3=A5s</b>"
                     "</b=\r\nody></html>\r\n"
                     "--_1_--\r\n"/utf8>>,
    {Diff1, Diff2} = isolate_difference(Mail2, ExpectedMail),
    ?assertEqual(Diff1, Diff2),
    ok.

parts_mail_1(_Config) ->
    TestMail = #{
      <<"mail">> => #{
          <<"from">> => <<"A B <a.b@c.se>">>,
          <<"to">> => [<<"z.u@d.se">>],
          <<"extra-headers">> => #{},
          <<"body">> => [
                         #{<<"headers">> => #{
                               <<"content-type">> => <<"multipart/alternative">>
                              },
                           <<"body">> => [
                                          #{<<"headers">> => #{
                                                <<"content-type">> => <<"text/plain">>
                                               },
                                            <<"body">> => <<"Plain text"/utf8>>
                                           },
                                          #{<<"headers">> => #{
                                                <<"content-type">> => <<"text/html">>
                                               },
                                            <<"body">> => <<"<html></html>">>
                                           }
                                         ]
                          },
                         #{<<"headers">> => #{
                               <<"content-type">> => <<"image/png">>,
                               <<"content-filename">> => <<"\"test.png\"">>
                              },
                           <<"body">> => <<"ABCDEF==">>
                          }
                        ]
         },
      <<"smtp">> => #{
          <<"relay">> => <<"smtp.nowhere.test">>,
          <<"port">> => 25,
          <<"username">> => <<"nobody">>,
          <<"password">> => <<"secret">>
         },
      <<"error">> => #{
          <<"to">> => <<"<admin@c.se>">>,
          <<"subject">> => <<"This is a subject">>,
          <<"body">> => <<"This is a message">>
         }
     },
    {ok,
     {smtp_event, {mail, _From, _To, Mail}, _SMTP, _ErrorInfo}
    } = qpusherl_smtp_event:parse(TestMail, ?DEFAULT_PARSE_OPTS),

    Mail3 = clean_up_mail(Mail),

    ExpectedMail = <<"From: A B <a.b@c.se>\r\n" "To: z.u@d.se\r\n" "Date: _\r\n"
                     "Content-Type: multipart/mixed;\r\n" "\tboundary=\"_1_\"\r\n"
                     "MIME-Version: 1.0\r\n" "Message-ID: _\r\n" "\r\n" "\r\n"
                     "--_1_\r\n" "Content-Type: multipart/alternative;\r\n"
                     "\tboundary=\"_2_\"\r\n" "Content-Disposition: inline\r\n"
                     "\r\n" "\r\n" "--_2_\r\n"
                     "Content-Type: text/plain;\r\n" "\tcharset=utf-8\r\n"
                     "Content-Disposition: inline\r\n"
                     "\r\n" "Plain text\r\n" "--_2_\r\n"
                     "Content-Type: text/html;\r\n" "\tcharset=utf-8\r\n"
                     "Content-Disposition: inline\r\n"
                     "\r\n" "<html></html>\r\n" "--_2_--\r\n" "\r\n" "--_1_\r\n"
                     "Content-Type: image/png\r\n"
                     "Content-Disposition: attachment;\r\n" "\t filename=\"test.png\"\r\n" "\r\n"
                     "ABCDEF==\r\n" "--_1_--\r\n">>,
    {Diff1, Diff2} = isolate_difference(ExpectedMail, Mail3),
    ?assertEqual(Diff2, Diff1),
    ?assertEqual(Diff1, <<>>),
    ?assertEqual(Diff2, <<>>),
    ok.


%% Removes common parts of A and B. Returns them trimmed by identical prefix
%% and suffix. This makes it easier to locate the difference between two large
%% binaries.
isolate_difference(A, B) ->
    PrefixLength = binary:longest_common_prefix([A, B]),
    <<_:PrefixLength/binary, A1/binary>> = A,
    <<_:PrefixLength/binary, B1/binary>> = B,
    {A1, B1}.

remove_boundaries([], _Count, Mail) ->
    Mail;
remove_boundaries([Boundary | Boundaries], Count, Mail0) ->
    Placeholder = <<"_", (list_to_binary(integer_to_list(Count)))/binary, "_">>,
    Mail1 = binary:replace(Mail0, Boundary, Placeholder, [global]),
    remove_boundaries(Boundaries, Count + 1, Mail1).

clean_up_mail(Mail0) ->
    Mail1 = case re:run(Mail0, <<"(?<=\r\n\tboundary=\")[^\r]+(?=\"\r\n)">>,
                        [{capture, all, binary}, global]) of
                {match, Boundaries} ->
                    remove_boundaries(Boundaries, 1, Mail0);
                nomatch -> Mail0
            end,
    Mail2 = re:replace(Mail1, <<"(?<=\r\nDate: )[^\r]+(?=\r\n)">>, <<"_">>,
                       [{return, binary}]),
    Mail3 = re:replace(Mail2, <<"(?<=\r\nMessage-ID: )[^\r]+(?=\r\n)">>, <<"_">>,
                       [{return, binary}]),
    Mail3.

