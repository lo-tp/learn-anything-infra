#!/usr/bin/env bash
#
# render-secrets.sh — copy Secret Manager values into cluster Secrets.
#
# The ownership boundary this sits on (AGENTS.md): Terraform creates the Secret
# *Manager entries* and their IAM; nothing in this repo holds their values; the
# workloads read cluster Secrets by stable name (`database-env`, `backend-env`,
# `sandbox-env`); this script is the bridge between the two, run at deploy time.
#
# It is deliberately boring and deliberately temporary. PLAN.md M7 replaces it with
# a pipeline step that does the same copy from the Terraform outputs instead of
# from this table, at which point the table below is deleted rather than grown.
# What M4 needs is a database password that exists, and one place where the
# cluster learns it.
#
# Usage:
#   scripts/render-secrets.sh <namespace> [target ...]     # e.g. database-env
#
# Runs as the human identity, like every other gcloud/kubectl target in the
# Makefile: kubectl needs the human credential for gke-gcloud-auth-plugin anyway,
# and that same identity reads Secret Manager as project owner. (The Terraform
# service account is a *secretmanager.accessor* too — gcp/secrets.tf — so the reads
# would work either way; the writes would not.)
set -euo pipefail

# Passed in rather than looked up: `make secrets` takes it from
# `terraform output project_id`, so the script does not need Terraform state
# credentials and there is still exactly one place that knows the value.
PROJECT_ID="${PROJECT_ID:?set PROJECT_ID, e.g. via `make secrets`}"; 

usage() {
  echo "usage: scripts/render-secrets.sh <namespace> [target ...]" >&2
  echo "targets: $(IFS=' '; echo "${!TARGETS[*]}")" >&2
  exit 2
}

# k8s Secret name -> the Secret Manager entries its keys come from, as KEY=SECRET.
#
# The names here are the contract the workloads compile against: base/*.yaml
# references these Secret names through envFrom, so renaming one here without
# renaming it there produces a pod that starts and then fails on an unset variable.
declare -A TARGETS=(
  [database-env]="POSTGRES_PASSWORD=db-password PGPASSWORD=db-password"
  [sandbox-env]="SANDBOX_SERVICE_TOKEN=sandbox-service-token"
  [backend-env]="JWT_SECRET=jwt-secret OPENAI_API_KEY=openai-api-key SANDBOX_SERVICE_TOKEN=sandbox-service-token"
)

# The backend wants one URL, `DATABASE_URL`, and names no driver in it: the app
# rewrites a driver-less `postgresql://` URL to psycopg3 itself
# (learn-anything-backend/db/models.py:45), which is how the same string works for
# the app engine and for `alembic/env.py`. Writing `postgresql+asyncpg://` here
# would survive that rewrite untouched and then fail, because that driver is not
# what this project depends on. The user, database and host below are
# the same facts base/database.yaml states for the server. Duplicating them is a
# wart: the honest fix is one source for connection facts, which M7 will have to
# decide anyway because the migration Job needs the same URL. Until then, if you
# change one of those four values, change it here too — `alembic upgrade head`
# failing with a connection error is how you find out otherwise.
DB_USER=learn
DB_NAME=learn_anything
DB_HOST=learn-anything-db

namespace="${1:-}"; shift || true
[ -n "$namespace" ] || usage

targets=("$@")
[ "${#targets[@]}" -gt 0 ] || targets=("${!TARGETS[@]}")

read_secret() {
  # `latest` rather than a pinned version: the value a deploy needs is the current
  # one, and Secret Manager keeps the history itself.
  gcloud secrets versions access latest \
    --project="$PROJECT_ID" --secret="$1" 2>/dev/null
}

literal_args=()
for target in "${targets[@]}"; do
  mapping="${TARGETS[$target]:-}"
  [ -n "$mapping" ] || { echo "unknown target: $target" >&2; usage; }

  literal_args=()
  for pair in $mapping; do
    key="${pair%%=*}"; secret="${pair#*=}"
    value="$(read_secret "$secret")"
    if [ -z "$value" ]; then
      echo "refusing to render $target: Secret Manager entry '$secret' is empty" >&2
      exit 1
    fi
    # The placeholder values M1 created are indistinguishable from real ones to a
    # script, so say it out loud rather than let a placeholder reach a pod silently.
    case "$value" in
      REPLACE_ME*) echo "note: '$secret' still holds its placeholder value" >&2 ;;
    esac
    literal_args+=("--from-literal=$key=$value")
  done

  if [ "$target" = "backend-env" ]; then
    password="$(read_secret db-password)"
    literal_args+=("--from-literal=DATABASE_URL=postgresql://${DB_USER}:${password}@${DB_HOST}:5432/${DB_NAME}")
  fi

  # `--dry-run=server` + apply: the server validates the object (including the
  # namespace existing) and apply is idempotent, so re-running this is a refresh
  # rather than a conflict.
  kubectl -n "$namespace" create secret generic "$target" \
    "${literal_args[@]}" \
    --dry-run=server -o yaml | kubectl apply -f -
  echo "rendered $target in namespace '$namespace' (${#literal_args[@]} args)" >&2
done
