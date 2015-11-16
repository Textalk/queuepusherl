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

The message format is fully described in `priv/schema/push_message.schema` but
here are two examples for clarity:

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

Versioning
----------

Queuepusherl intends to employs [Semantic Versioning 2.0.0](http://semver.org/spec/v2.0.0.html)
