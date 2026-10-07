# Terraform and kubectl reach GCP through a local HTTP proxy from mainland
# China; see the "Network" section of AGENTS.md for why. Override GCP_PROXY if
# your client listens on another port.
GCP_PROXY ?= http://127.0.0.1:6152
GCP_ENV    = HTTPS_PROXY=$(GCP_PROXY) HTTP_PROXY=$(GCP_PROXY) NO_PROXY=localhost,127.0.0.1
GCRED     ?= $(HOME)/.config/gcp/learn-anything-510905.json
AUTH       = GOOGLE_APPLICATION_CREDENTIALS=$(GCRED)

# Which root to act on. bootstrap/ first, then gcp/.
ROOT ?= gcp

tf-fmt:
	terraform fmt -recursive

tf-init:
	cd $(ROOT) && $(AUTH) $(GCP_ENV) terraform init

tf-plan:
	cd $(ROOT) && $(AUTH) $(GCP_ENV) terraform plan

tf-apply:
	cd $(ROOT) && $(AUTH) $(GCP_ENV) terraform apply

tf-output:
	cd $(ROOT) && $(AUTH) $(GCP_ENV) terraform output

tf-bootstrap:
	$(MAKE) tf-init tf-apply tf-output ROOT=bootstrap

kubectl = $(AUTH) $(GCP_ENV) kubectl

.PHONY: tf-fmt tf-init tf-plan tf-apply tf-output
