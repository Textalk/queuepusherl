# Queuepusherl

Queuepusherl listens to a RabbitMQ channel (default `queuepusherl`) and accepts messages that
contains instructions for pushing a message to a untrusted remote server of some sort. It currently
handles SMTP and HTTP requests and takes slightly different parameters depending on the type.

## Incoming messages

An incoming message matches the schema in `priv/schema/push_message.schema`

## SMTP

An incoming SMTP push needs to contain information about what message is being sent, by which relay
and where to send any potential errors.

### SMTP - mail property

The mail structure contains information about who is sending the mail, where to send it and a body.
Besides that information a subject line can be added in the "extra-headers" property (by adding the
key "subject" with the line as a parameter) and any other necessary information.

### Sending

As the message is received the e-mail is sent out. If it succeeds the message is acknowledged to the
broker and the process is shutdown. If the e-mail fails a predetermined number of times (default is
10) an error mail is sent to the user specified in the error portion of the message. Each time it
fails, the back-off time (time to wait until retry) is increased exponentially.


