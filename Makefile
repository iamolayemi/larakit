COMPOSE = docker compose -f docker/docker-compose.yml
IMAGE   = larakit-test
CTR     = larakit-dev

.PHONY: build shell test syntax-check test-libs test-cli lint fmt fmt-check run-module install uninstall clean

build:
	$(COMPOSE) build

shell:
	$(COMPOSE) run --rm larakit bash

test: syntax-check test-libs test-cli

syntax-check:
	@bash tests/syntax-check.sh

test-libs:
	@bash tests/test-libs.sh

test-cli:
	@LARAKIT_HOME=$(PWD) bash tests/test-cli.sh
	@# Note: requires bash 4+ — on macOS run: brew install bash

lint:
	@shellcheck --rcfile=.shellcheckrc --severity=warning $$(find . -name "*.sh" -not -path "./.git/*") larakit

fmt:
	@shfmt -w -i 2 -bn -ci -sr $$(find . -name "*.sh" -not -path "./.git/*") larakit

fmt-check:
	@shfmt -d -i 2 -bn -ci -sr $$(find . -name "*.sh" -not -path "./.git/*") larakit

# Install the larakit CLI to /usr/local/bin (requires sudo)
install:
	sudo bash install.sh

# Remove larakit from /usr/local/bin and /opt/larakit
uninstall:
	sudo rm -f /usr/local/bin/larakit /etc/bash_completion.d/larakit
	sudo rm -rf /opt/larakit
	@echo "larakit uninstalled."

# Run a single module inside Docker (non-interactively for testing)
# Usage: make run-module MODULE=03-php.sh
run-module:
	$(COMPOSE) run --rm larakit bash modules/$(MODULE)

clean:
	$(COMPOSE) down --rmi local --volumes --remove-orphans 2>/dev/null || true
	docker rmi $(IMAGE) 2>/dev/null || true
