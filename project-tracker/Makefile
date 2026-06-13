# Marginalia — build + deploy helpers.
#
# Deploy ships origin/main to the MacMini (andrews-mac-mini). The mini builds
# host-native artifacts and restarts its LaunchAgents. Commit + push first.
#
#   make deploy         pull origin/main on the mini, build, restart, health-check
#   make deploy-check   report the mini's deploy state, change nothing
#   make build          local build (server + frontend)
#   make bundle         bundle the frontend locally

.PHONY: help deploy deploy-check build bundle

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

deploy: ## Ship origin/main to the MacMini (pull, build, restart, health-check)
	bash tools/deploy/deploy.sh

deploy-check: ## Report the MacMini's deploy state without changing anything
	bash tools/deploy/deploy.sh --check

build: ## Local build (server + frontend)
	npm run build

bundle: ## Bundle the frontend locally
	npm run bundle:frontend
