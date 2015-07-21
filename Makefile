PROJECT = queuepusherl
RABBITMQ_CLIENT_PATCH = 1
DEPS = lager cowlib jiffy gen_smtp amqp_client
TEST_DEPS = meck

CT_OPTS = -ct_hooks queuepusherl_ct_hook []
ERLC_OPTS += +'{parse_transform, lager_transform}'

include erlang.mk
