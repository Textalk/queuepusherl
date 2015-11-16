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

ERLANG_MK_COMMIT = 2.0.0-pre.1

ifeq ("$(wildcard erlang.mk)", "")
## The following case is used to download the correct version of erlang.mk
ERLANG_MK_REPO = https://github.com/ninenines/erlang.mk
ERLANG_MK_BUILD_CONFIG = build.config
ERLANG_MK_BUILD_DIR = .erlang.mk.build

.PHONY: bootstrap-erlang-mk help

bootstrap-erlang-mk:
	@git clone $(ERLANG_MK_REPO) $(ERLANG_MK_BUILD_DIR)
	@if [ -f $(ERLANG_MK_BUILD_CONFIG) ]; then cp $(ERLANG_MK_BUILD_CONFIG) $(ERLANG_MK_BUILD_DIR)/build.config; fi
	@cd $(ERLANG_MK_BUILD_DIR) && $(if $(ERLANG_MK_COMMIT),git checkout $(ERLANG_MK_COMMIT) &&) $(MAKE)
	@cp $(ERLANG_MK_BUILD_DIR)/erlang.mk ./erlang.mk
	@rm -rf $(ERLANG_MK_BUILD_DIR)
	@echo -e "\nerlang.mk has been downloaded, run make again to build application"

help:
	@echo -e "run `make bootstrap-erlang-mk` before building your application"

all: bootstrap-erlang-mk
else
include erlang.mk

help::
	$(verbose) printf "%s\n" "" \
		"Release configuration:" \
		"Specify release config by setting the environmental variable REL to one of" \
		"'test', 'stage' or 'production'."
endif
