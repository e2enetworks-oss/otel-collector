SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
.PHONY: help lint test

help: ## Show available targets
	@echo "make lint — check installer shell syntax"
	@echo "make test — run installer tests"

lint: ## Lint the installer
	shellcheck install.sh

test: ## Run installer tests
	bats tests/
