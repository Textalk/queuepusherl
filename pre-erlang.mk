ifeq ("$(wildcard erlang.mk)", "")
## The following case is used to download the correct version of erlang.mk
ERLANG_MK_REPO ?= https://github.com/ninenines/erlang.mk
ERLANG_MK_BUILD_CONFIG ?= build.config
ERLANG_MK_BUILD_DIR ?= .erlang.mk.build

.PHONY: bootstrap-erlang-mk

all: bootstrap-erlang-mk

bootstrap-erlang-mk:
	@git clone $(ERLANG_MK_REPO) $(ERLANG_MK_BUILD_DIR)
	@if [ -f $(ERLANG_MK_BUILD_CONFIG) ]; then cp $(ERLANG_MK_BUILD_CONFIG) $(ERLANG_MK_BUILD_DIR)/build.config; fi
	@cd $(ERLANG_MK_BUILD_DIR) && $(if $(ERLANG_MK_COMMIT),git checkout $(ERLANG_MK_COMMIT) &&) $(MAKE)
	@cp $(ERLANG_MK_BUILD_DIR)/erlang.mk ./erlang.mk
	@rm -rf $(ERLANG_MK_BUILD_DIR)
	@echo -e "\nerlang.mk has been downloaded, run make again to build application"

else
include erlang.mk
endif
