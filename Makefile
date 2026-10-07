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
	cd $(ROOT) && $(AUTH) $(GCP_ENV) terraform apply $(TF_ARGS)

# Non-interactive apply, for when the review already happened: `make tf-apply-yes`.
# Split rather than the default, because an apply that never asks is an apply that
# can spend money while you are not looking.
tf-apply-yes:
	$(MAKE) tf-apply TF_ARGS=-auto-approve

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

# The namespace the production overlay deploys into, kept next to the Terraform
# variable of the same name (variables.tf explains why both exist).
NS ?= learn-anything
PROJECT_ID := $(shell $(AUTH) $(GCP_ENV) terraform -chdir=gcp output -raw project_id 2>/dev/null)

# Copy Secret Manager values into the cluster Secrets the workloads read by name
# (scripts/render-secrets.sh). This is the interim form; M7 puts the same step in
# the pipeline. It runs as the human identity, like every gcloud/kubectl target
# here: kubectl needs the human credential for the auth plugin, and that identity
# can read Secret Manager because it is the project owner.
secrets:
	$(kenv) PROJECT_ID=$(PROJECT_ID) ./scripts/render-secrets.sh $(NS) $(SECRETS)

.PHONY: tf-fmt tf-init tf-plan tf-apply tf-apply-yes tf-output secrets kcreds kcheck
