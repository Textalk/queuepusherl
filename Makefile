PROJECT = queuepusherl
RABBITMQ_CLIENT_PATCH = 1
DEPS = gun jiffy gen_smtp amqp_client
TEST_DEPS = meck

CT_OPTS = -ct_hooks queuepusherl_ct_hook []

include erlang.mk
