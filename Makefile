PROJECT = queuepusherl
PROJECT_NAME = queuepusher
PROJECT_DESCRIPTION = Micro-service for doing HTTP and SMTP requests.
PROJECT_VERSION = 0.5.0
LOCAL_DEPS = inets ssl
DEPS = lager cowlib jiffy gen_smtp amqp_client
TEST_DEPS = meck

CT_OPTS = -ct_hooks queuepusherl_ct_hook []
EXTRA_ERLC_OPTS = +'{parse_transform, lager_transform}'
ERLC_OPTS += ${EXTRA_ERLC_OPTS}
TEST_ERLC_OPTS += ${EXTRA_ERLC_OPTS}

ERLANG_MK_COMMIT = 2.0.0-pre.1

include pre-erlang.mk

help::
	$(verbose) printf "%s\n" "" \
		"Release configuration:" \
		"Specify release config by setting the environmental variable REL to one of" \
		"'test', 'stage' or 'production'."

REL ?= testing
PROJECT_PACK_NAME = $(PROJECT_NAME)-$(REL)-$(PROJECT_VERSION).tar.bz2

.PHONY: rel-pack

rel-pack: $(PROJECT_PACK_NAME)

$(PROJECT_PACK_NAME):
	@echo "Create pack $(PROJECT_PACK_NAME)"
	tar --create --preserve-permissions --bzip2 \
		--file=$(PROJECT_PACK_NAME) \
		--directory=$(RELX_OUTPUT_DIR)/$(PROJECT_NAME) \
		--one-file-system \
		--recursion \
		. ../.././README.md
