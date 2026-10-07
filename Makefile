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

# kubectl authenticates through gcloud and gke-gcloud-auth-plugin, which needs the
# bundled SDK on PATH and the *human* credential — the plugin crashes when the
# active gcloud credential is a service-account key (AGENTS.md, "Cluster access").
# Keeping these targets apart from the Terraform ones is what stops one identity
# leaking into the other's work.
SDK        = $(CURDIR)/google-cloud-sdk/bin
KUBECONFIG ?= $(CURDIR)/.kubeconfig-gke
kenv = PATH="$(SDK):$(PATH)" KUBECONFIG=$(KUBECONFIG) $(GCP_ENV)

kcreds:
	$(kenv) gcloud container clusters get-credentials learn-anything --region=asia-east2

# The M1 readiness check. `get nodes` reporting nothing is the expected state for
# an idle Autopilot cluster; the control plane answering is the part that matters.
kcheck:
	$(kenv) kubectl get --raw /readyz
	$(kenv) kubectl get ns
	$(kenv) kubectl get nodes || true

.PHONY: tf-fmt tf-init tf-plan tf-apply tf-output kcreds kcheck
