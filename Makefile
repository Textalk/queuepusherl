PROJECT = queuepusherl
PROJECT_DESCRIPTION = Micro-service for doing HTTP and SMTP requests.
PROJECT_REGISTERED = qpusherl_app
PROJECT_VERSION = 0.4.0
LOCAL_DEPS = inets ssl
DEPS = lager cowlib jiffy gen_smtp amqp_client
TEST_DEPS = meck

CT_OPTS = -ct_hooks queuepusherl_ct_hook []
EXTRA_ERLC_OPTS = +'{parse_transform, lager_transform}'
ERLC_OPTS += ${EXTRA_ERLC_OPTS}
TEST_ERLC_OPTS += ${EXTRA_ERLC_OPTS}

include erlang.mk

help::
	$(verbose) printf "%s\n" "" \
		"Release configuration:" \
		"Specify release config by setting the environmental variable REL to one of" \
		"'test', 'stage' or 'production'."
