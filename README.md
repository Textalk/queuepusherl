Queuepusherl
============

An erlang implementation of the Queuepush micro-service that listens to a AMQP
(RabbitMQ) queue and performs HTTP or SMTP requests on received messages.

RabbitMQ
--------

Queuepusherl uses two exchanges:

  * `qpush.exchange` - Used for receiving messages and returning error reports.
    * `qpush.queue.work` - This is the queue where messages posted to
      `qpush.exchange` with the key `queuepush` will end up.
    * `qpush.queue.response` - Responses to a request is sent on this queue, in
                               the case of a success the response will be a list
                               of positive results, if it's a failure it will
                               contain the request itself and store the errors
                               in the header `x-qpush-errors`.
  * `qpush.dlx` - This is a dead-letter exchange just for internal use, it is
    used to delay requeuing of messages if they fail.

Message format
--------------

The message format is fully described in `priv/schema/push_message.schema` and
exemplified below:

E-mail with text and html alternatives. In case the message can't be sent it
will be sent to "admin@example.com" instead with the error body as message.

```JSON
{
  "type": "smtp",
  "data": {
    "mail": {
      "from": "Us <us@example.com>",
      "to": ["User <them@example.com>"],
      "subject": "Subject of mail",
      "content-type": "multipart/alternative",
      "extra-headers": {},
      "body": [
        {
          "headers": {
            "content-type": "text/plain"
          },
          "body": "Plain text mail"
        },
        {
          "headers": {
            "content-type": "text/html"
          },
          "body": "<body>HTML version of mail</body>"
        }
      ]
    },
    "smtp": {
      "relay": "smtp.relay.com",
      "port": 25,
      "username": "user",
      "password": "secret"
    },
    "error": {
      "to": "Admin <admin@example.com>",
      "subject": "This is an error",
      "body": "Body of error mail, failed mail will be attached"
    }
  }
}
```

A simple HTTP POST to `http://example.com` with the body set to `foo=bar`.
```JSON
{
  "type": "http",
  "data": {
    "request": {
      "method": "POST",
      "url": "http://example.com",
      "require-success": true,
      "extra-headers": {},
      "content-type": "application/x-www-form-urlencoded",
      "data": {
        "foo": "bar"
      }
    }
  }
}
```

Message Format - SMTP
=====================

An SMTP message needs to contain a `mail` and `smtp` value. In the case where
there are no `error` value no SMTP request will be done if the primary message
could not be sent.

As for the `body` of the message it can contain either a simple string that will
be processed as a `text/plain` unless another `content-type` is explicitly
specified. If there is a list of bodies each sub-body can, recursively, contain
either a string or a list of sub-bodies. And unless otherwise specified the
`content-type` will be assumed to be `multipart/mixed`.

Important to note is that the `to`, `cc` and `bcc` fields for the primary
message needs to be a list of addresses while the `from` field is only allowed
to be one address.

In the case of multiple SMTPs specified for the primary message these will all
be tried in order until one of them succeeds. This means that if the first SMTP
relay isn't accessible for some reason the second one will be attempted and so
on.

Versioning
----------

Queuepusherl intends to employs
[Semantic Versioning 2.0.0](http://semver.org/spec/v2.0.0.html)

// vim: tw=80: ft=markdown
