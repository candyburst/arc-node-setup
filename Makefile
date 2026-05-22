SHELL := /usr/bin/env bash

.PHONY: test check

test:
	bash -n setup.sh
	bash tests/smoke.sh

check: test
