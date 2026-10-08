# Terraform and kubectl reach GCP through a local HTTP proxy from mainland
# China; see the "Network" section of AGENTS.md for why. Override GCP_PROXY if
# your client listens on another port.
GCP_PROXY ?= http://127.0.0.1:6152
GCP_ENV    = HTTPS_PROXY=$(GCP_PROXY) HTTP_PROXY=$(GCP_PROXY) NO_PROXY=localhost,127.0.0.1
GCRED     ?= $(HOME)/.config/gcp/learn-anything-510905.json
AUTH       = GOOGLE_APPLICATION_CREDENTIALS=$(GCRED)

# Which root to act on. bootstrap/ first, then gcp/.
ROOT ?= gcp

# Bare `make` prints this rather than running something: an infrastructure
# Makefile whose default action is `terraform fmt` is a way to spend an afternoon
# by accident. `make help` says the same on purpose.
.DEFAULT_GOAL := help

help: ## this list
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ''
	@echo 'Variables: ROOT=bootstrap|gcp (default gcp), NS=$(NS), ENV=prod|staging (deploy),'
	@echo '           SECRETS=name,name (render one), CHECK_ONLY=1 (validate, do not write),'
	@echo '           TF_ARGS=-auto-approve, SKIP_MIGRATE=1 (deploy).'
	@echo 'Machine: GCP_PROXY=$(GCP_PROXY), GCRED=$(GCRED), SDK=$(SDK),'
	@echo '         KUBECONFIG=$(KUBECONFIG), REPO_ROOT (secret-hygiene: the parent of'
	@echo '         this repo unless overridden). Nothing here is a fact about one laptop.'

tf-fmt: ## format the Terraform roots
	terraform fmt -recursive

tf-init: ## terraform init in the chosen ROOT
	cd $(ROOT) && $(AUTH) $(GCP_ENV) terraform init

tf-plan: ## terraform plan in $(ROOT), through the proxy
	cd $(ROOT) && $(AUTH) $(GCP_ENV) terraform plan

tf-apply: ## terraform apply in $(ROOT), asking first
	cd $(ROOT) && $(AUTH) $(GCP_ENV) terraform apply $(TF_ARGS)

# Non-interactive apply, for when the review already happened: `make tf-apply-yes`.
# Split rather than the default, because an apply that never asks is an apply that
# can spend money while you are not looking.
tf-apply-yes: ## apply without asking, when the review already happened
	$(MAKE) tf-apply TF_ARGS=-auto-approve

tf-output: ## show the chosen root's outputs
	cd $(ROOT) && $(AUTH) $(GCP_ENV) terraform output

tf-bootstrap: ## init, apply and print outputs for the bootstrap/ root
	$(MAKE) tf-init tf-apply tf-output ROOT=bootstrap

# kubectl authenticates through gcloud and gke-gcloud-auth-plugin, which needs the
# bundled SDK on PATH and the *human* credential — the plugin crashes when the
# active gcloud credential is a service-account key (AGENTS.md, "Cluster access").
# Keeping these targets apart from the Terraform ones is what stops one identity
# leaking into the other's work.
# Where gcloud and gke-gcloud-auth-plugin live. The SDK is gitignored and belongs
# outside the repo; on a machine where it is installed the normal way, override:
#   make kcreds SDK=/opt/homebrew/bin
SDK ?= $(CURDIR)/google-cloud-sdk/bin
KUBECONFIG ?= $(CURDIR)/.kubeconfig-gke
# Anything that shells out to gcloud needs the bundled SDK on PATH; anything that
# talks to the cluster additionally needs the generated kubeconfig. Split so a
# gcloud-only target does not pretend to be a kubectl one.
gcloudenv = PATH="$(SDK):$(PATH)" $(GCP_ENV)
kenv = $(gcloudenv) KUBECONFIG=$(KUBECONFIG)

kcreds: ## point .kubeconfig-gke at the cluster, as the human identity
	$(kenv) gcloud container clusters get-credentials learn-anything --region=asia-east2

# The M1 readiness check. `get nodes` reporting nothing is the expected state for
# an idle Autopilot cluster; the control plane answering is the part that matters.
kcheck: ## prove the control plane answers (no nodes on an idle Autopilot cluster is normal)
	$(kenv) kubectl get --raw /readyz
	$(kenv) kubectl get ns
	$(kenv) kubectl get nodes || true

# The namespace the production overlay deploys into, kept next to the Terraform
# variable of the same name (variables.tf explains why both exist).
NS ?= learn-anything
PROJECT_ID := $(shell $(AUTH) $(GCP_ENV) terraform -chdir=gcp output -raw project_id 2>/dev/null)

# Copy Secret Manager values into the cluster Secrets the workloads read by name
# (scripts/render-secrets.sh). This is the interim form; M7 puts the same step in
# the pipeline. It runs as the human identity, like every gcloud/kubectl target
# here: kubectl needs the human credential for the auth plugin, and that identity
# can read Secret Manager because it is the project owner.
# `SECRETS=name[,name]` renders a subset; `CHECK_ONLY=1` validates against the API
# without writing. A rendered Secret is not yet a running value: a container keeps
# the environment it started with, so a rotation reaches a pod when it is replaced.
secrets: ## render Secret objects from Secret Manager (SECRETS=… to target, CHECK_ONLY=1 to validate)
	$(kenv) PROJECT_ID=$(PROJECT_ID) ./scripts/render-secrets.sh $(NS) $(SECRETS)

# The public surface, not the deploy: four things have to agree for a hostname to
# answer — the host list Terraform declares, the Ingress and certificate the
# cluster is running, the records at the registrar (typed by hand — ADR 0004), and
# the certificate Google issued. Any one of them being behind the others looks
# like a broken deploy from a browser, so this asks each one out loud.
# Read-only; exits non-zero on any disagreement.
dns-check: ## is the public surface the one this repo says it is?
	$(kenv) NAMESPACE=$(NS) ./scripts/dns-check.sh

# The M5 order: migration Job first, then the workloads, then the rollout. It reads
# the image out of the overlay rather than from the command line, so what gets
# migrated and what gets deployed cannot disagree. `make deploy ENV=staging` for
# the other one; staging's database is asleep, so it needs SKIP_MIGRATE=1 or a
# woken database.
deploy: ## the M5 order: migrate, apply, wait (ENV=prod|staging)
	$(kenv) NAMESPACE=$(NS) ./scripts/deploy.sh $(ENV)

# M7's two checks, both read-only. `secrets-check` compares the names
# render-secrets.sh maps against the names gcp/app_secrets.tf creates — the two
# lists live in one repository and can still disagree silently. `secret-hygiene`
# proves no secret value appears in any of the four repositories or inside a
# running image, and that JWT_SECRET and SANDBOX_SERVICE_TOKEN are one value each
# across the pods that read them. Neither prints a value; both compare hashes.
secrets-check: ## do the Terraform secret names and the renderer's mapping agree?
	$(AUTH) $(GCP_ENV) ./scripts/check-secret-names.sh

secret-hygiene: ## no secret in a repo or an image, and the shared pairs match
	$(kenv) PROJECT_ID=$(PROJECT_ID) ./scripts/secret-hygiene.sh $(NS)

# What the registry now holds as published, written into the production overlay.
# Same script the scheduled pin-image workflow runs; committing the result is
# still a human act, which is why this does not commit for you.
pin-images: ## pin production to the newest published images by hand (CI does this on release)
	$(kenv) PROJECT_ID=$(PROJECT_ID) ./scripts/pin-image.sh

# M8's acceptance walk: one complete session through the public surface, printed as
# a table (register → sign in → clarify → probe → plan → approve → materials → the
# sandbox's iframe fetch of a slide → and the rule that /api/compile is not a
# public route). It reports which mode the live Deployment says it is in, because a
# mock pass and a real pass are different claims. `ALLOW_FAIL=1` is for the
# real-mode control run, where the LLM phases are expected to fail.
acceptance: ## walk one session through the public surface
	NO_PROXY=localhost,127.0.0.1 python3 scripts/acceptance.py $(ARGS)

# MOCK_LLM=1 makes the backend answer its LLM-dependent phases from canned
# responses on in-memory SQLite — the cheapest full walk of DNS, TLS, routing,
# probes and the sandbox fetch, and it spends no tokens. Setting it by hand is
# deliberate drift: `make deploy` (or a CI deploy) removes it, which is the point.
mock-on: ## set MOCK_LLM=1 on the live backend (drift on purpose; make deploy reverts it)
	$(kenv) kubectl -n $(NS) set env deployment/backend MOCK_LLM=1

mock-off: ## take MOCK_LLM off without waiting for a deploy
	$(kenv) kubectl -n $(NS) set env deployment/backend MOCK_LLM-

# The restore drill (M9): read the newest nightly archive back into a throwaway
# database in the same cluster and compare table shapes. A backup that has never
# been read is a hope, not a recovery path. Tears the scratch pod down on exit.
restore-drill: ## pg_restore the newest archive into a scratch database and compare
	$(kenv) DUMP_BUCKET=$(shell $(AUTH) $(GCP_ENV) terraform -chdir=gcp output -raw pgdump_bucket 2>/dev/null) ./scripts/restore-drill.sh $(NS)

# M10: the numbers instead of the estimates. Needs the BigQuery billing export,
# which is a one-time console act and is not backfilled — the script says so and
# exits 2 rather than pretending. Credits are reported separately from cost on
# purpose: the trial credit makes the invoice small, not the platform cheap.
# Reads a gcloud access token, so it runs as the human identity like the other
# human targets — not as terraform-local.
cost-report: ## what the platform actually costs, by service and SKU
	$(gcloudenv) python3 scripts/cost-report.py $(ARGS)

.PHONY: help tf-fmt dns-check tf-init tf-plan tf-apply tf-apply-yes tf-output secrets deploy kcreds kcheck secrets-check secret-hygiene pin-images acceptance mock-on mock-off restore-drill cost-report
