PROJECT = queuepusherl
PROJECT_DESCRIPTION = Micro-service for doing HTTP and SMTP requests.
PROJECT_VERSION = 0.2.0
RABBITMQ_CLIENT_PATCH = 1
LOCAL_DEPS = inets ssl
DEPS = lager cowlib jiffy gen_smtp amqp_client
#DEPS = lager gun jiffy gen_smtp amqp_client
TEST_DEPS = meck

CT_OPTS = -ct_hooks queuepusherl_ct_hook []
EXTRA_ERLC_OPTS = +'{parse_transform, lager_transform}'
ERLC_OPTS += ${EXTRA_ERLC_OPTS}
TEST_ERLC_OPTS += ${EXTRA_ERLC_OPTS}

include erlang.mk
