# DevOps QR capstone: every step from a clean laptop to a public URL and back to $0.
# Each target runs one script in scripts/ (or a one-liner). `make help` lists them.
include project.env
include tool-versions.env

SHELL := /bin/bash
.DEFAULT_GOAL := help
.NOTPARALLEL:

SCOPE ?= main
CLUSTER ?= eks
S := ./scripts

.PHONY: help tools doctor lint test fmt build local-up local-smoke local-logs local-down \
	kind-up kind-deploy kind-smoke kind-monitoring kind-down gh-repo gh-setup gh-teardown \
	bootstrap infra-plan infra-up kubeconfig platform-up monitoring-up release deploy url \
	smoke-test grafana status up lb-cleanup infra-down nuke verify-clean

##@ Setup
help: ## List every target
	@awk 'BEGIN {FS = ":.*## "} /^##@/ {printf "\n%s\n", substr($$0, 5)} /^[a-z][a-z-]*:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

tools: ## Install every CLI tool with Homebrew (brew bundle)
	brew bundle --file=Brewfile

doctor: ## Check tools and versions, Docker, AWS and GitHub logins
	$(S)/doctor.sh

##@ Quality
lint: ## All static checks CI runs (shell, actions, Dockerfiles, terraform, k8s, monitoring)
	$(S)/lint.sh all

test: ## App tests in the Dockerfile test stages (api: ruff+pytest, web: eslint)
	$(S)/test.sh

fmt: ## terraform fmt -recursive infra
	terraform fmt -recursive infra

##@ Local (Docker Compose)
build: ## Build native qr-api:dev and qr-web:dev images
	$(S)/build.sh

local-up: ## Start MinIO + API + web with compose; http://localhost:3000
	$(S)/local.sh up

local-smoke: ## Smoke test http://localhost:3000
	$(S)/local.sh smoke

local-logs: ## Last 200 log lines from every compose service
	$(S)/local.sh logs

local-down: ## Stop compose and delete its volumes
	$(S)/local.sh down

##@ Local Kubernetes (kind)
kind-up: ## Create kind cluster qr-kind (port 8080 -> NodePort 30080)
	$(S)/kind.sh up

kind-deploy: ## Build images, kind load, apply the local overlay, wait for rollout
	$(S)/kind.sh deploy

kind-smoke: ## Smoke test http://localhost:8080
	$(S)/kind.sh smoke

kind-monitoring: ## Install kube-prometheus-stack + QR dashboard on kind
	$(S)/kind.sh monitoring

kind-down: ## Delete the kind cluster
	$(S)/kind.sh down

##@ GitHub
gh-repo: ## Create the private repo devops-qr-capstone and push main
	$(S)/gh-repo.sh

gh-setup: ## Copy Terraform outputs into GitHub repo variables
	$(S)/gh-setup.sh

gh-teardown: ## Delete repo variables: SCOPE=main (default) or SCOPE=all
	$(S)/gh-teardown.sh $(SCOPE)

##@ Cloud up (AWS)
bootstrap: ## Apply infra/bootstrap (state bucket, OIDC, CI roles), then gh-setup
	$(S)/bootstrap.sh

infra-plan: ## terraform plan for infra/main (read-only)
	$(S)/infra.sh plan

infra-up: ## Preflight, apply infra/main (~15-20 min), kubeconfig, gh-setup
	$(S)/infra.sh up

kubeconfig: ## Write kubeconfig context devops-qr-eks
	$(S)/cloud.sh kubeconfig

platform-up: ## Namespace qr-app + monitoring on EKS (cluster-admin steps)
	$(S)/cloud.sh platform-up

monitoring-up: ## kube-prometheus-stack + dashboard on EKS (CLUSTER=kind for kind)
	$(S)/monitoring-up.sh $(CLUSTER)

release: ## Run app.yml on main in GitHub Actions and wait (build, push, deploy, smoke)
	$(S)/release.sh

deploy: ## Laptop escape hatch: deploy origin/main's SHA (images must be in ECR)
	$(S)/cloud.sh deploy

url: ## Print the public URL http://<nlb-dns>
	@$(S)/url.sh

smoke-test: ## Smoke test the public URL
	$(S)/smoke-test.sh "$$($(S)/url.sh)"

grafana: ## Print Grafana login, port-forward to http://localhost:3001 (CLUSTER=kind for kind)
	$(S)/grafana.sh $(CLUSTER)

status: ## Nodes, pods, services, URL and recent CI runs
	$(S)/cloud.sh status

up: ## Everything: bootstrap, infra-up, platform-up, release, smoke-test
	$(MAKE) bootstrap
	$(MAKE) infra-up
	$(MAKE) platform-up
	$(MAKE) release
	$(MAKE) smoke-test

##@ Teardown
lb-cleanup: ## Remove leftover load balancers, k8s-* SGs and detached ENIs in the VPC
	$(S)/lb-cleanup.sh

infra-down: ## Remove the main stack in safe order (keeps bootstrap)
	$(S)/infra-down.sh

nuke: ## Back to zero cost: infra-down, bootstrap destroy, all repo variables, verify-clean
	$(S)/nuke.sh

verify-clean: ## List anything billable left; exits 1 if something is found
	$(S)/verify-clean.sh
