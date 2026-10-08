#!/usr/bin/env bash
#
# render-secrets.sh — copy Secret Manager values into cluster Secrets.
#
# The ownership boundary this sits on (AGENTS.md): Terraform creates the Secret
# *Manager entries* and their IAM; nothing in this repo holds their values; the
# workloads read cluster Secrets by stable name (`database-env`, `backend-env`,
# `sandbox-env`); this script is the bridge between the two, run at deploy time.
#
# It is deliberately boring. What M7 changed is not this table but who runs it and
# how often: it is now a step in `.github/workflows/deploy.yml`, running as the
# pipeline's own keyless identity (see scripts/ci-kubeconfig.sh), so a deploy from
# CI and a deploy from a laptop are the same order of operations. The table below
# stays, because it is the mapping from Secret Manager entries to the environment
# variable names the apps compile against — Terraform owns which entries *exist*
# (`gcp/app_secrets.tf` records why the names match), not what the cluster calls
# them. Keeping the two lists in step is `make secrets-check`'s job.
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

# Resolved by one place rather than passed around by every caller: an explicit
# PROJECT_ID still wins, and without one the value comes from scripts/project-id.sh
# (this repository's declared value, then the state). The old form demanded the
# variable, which turned an upstream resolution failure into an error message here.
PROJECT_ID="${PROJECT_ID:-$("$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"/project-id.sh)}"

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
  # The frontend needs exactly one secret: proxy.ts verifies the sign-in cookie with
  # the same JWT signing key the backend issues it with, which is why it is the same
  # Secret Manager entry and not a second one. Its NEXT_PUBLIC_* values are build
  # arguments baked into the image, so they are deliberately absent here.
  # The frontend needs exactly one secret: proxy.ts verifies the sign-in cookie with
  # the same JWT signing key the backend issues it with, which is why it is the same
  # Secret Manager entry and not a second one. Its NEXT_PUBLIC_* values are build
  # arguments baked into the image, so they are deliberately absent here.
  [frontend-env]="JWT_SECRET=jwt-secret"
)

# Pairs that are skipped when their entry is still empty, instead of failing the
# render. `openai-base-url` and `llm-model` are declared by Terraform now and
# filled at M8, when the real LLM is switched on; a deploy before then should not
# invent an empty `OPENAI_BASE_URL=`, because the backend reads an empty string as
# "use the configured value" and passes it to the client, which is a worse failure
# than the variable being unset.
OPTIONAL_TARGETS=(backend-env)
OPTIONAL_pairs="OPENAI_BASE_URL=openai-base-url LLM_MODEL=llm-model"

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
DB_PASSWORD_SECRET=db-password

namespace="${1:-}"; shift || true
[ -n "$namespace" ] || usage

# Sorted, so a full run is reproducible in its output rather than dependent on the
# order bash happens to iterate a associative array in.
targets=("$@")
[ "${#targets[@]}" -gt 0 ] || targets=($(printf '%s\n' "${!TARGETS[@]}" | sort))

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
  pairs_for_target="$mapping"
  for t in "${OPTIONAL_TARGETS[@]}"; do
    [ "$t" = "$target" ] && pairs_for_target="$mapping $OPTIONAL_pairs"
  done
  for pair in $pairs_for_target; do
    key="${pair%%=*}"; secret="${pair#*=}"
    # `|| true` because a Secret Manager entry with an empty payload makes gcloud
    # exit non-zero, and `set -e` would end the script before the branch below can
    # say which kind of empty this is.
    value="$(read_secret "$secret" || true)"
    if [ -z "$value" ]; then
      case " $OPTIONAL_pairs " in
        *" $pair "*) echo "note: skipping $key — Secret Manager entry '$secret' is empty (supplied at M8)" >&2; continue ;;
      esac
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
    password="$(read_secret "$DB_PASSWORD_SECRET" || true)"
    literal_args+=("--from-literal=DATABASE_URL=postgresql://${DB_USER}:${password}@${DB_HOST}:5432/${DB_NAME}")
  fi

  rendered="$(kubectl -n "$namespace" create secret generic "$target" \
    "${literal_args[@]}" --dry-run=client -o yaml)"

  if [ "${CHECK_ONLY:-0}" = "1" ]; then
    # Validation without writing. `create --dry-run=server` would refuse an object
    # that already exists, which is exactly the re-run case, so the validating path
    # is an apply with a server dry-run.
    printf '%s\n' "$rendered" | kubectl apply --dry-run=server -f - >/dev/null
    echo "validated $target in namespace '$namespace' (CHECK_ONLY=1: nothing written)" >&2
    continue
  fi

  # `apply`, not `create`: a re-run has to update the object instead of refusing it,
  # because that is how a rotated Secret Manager value gets as far as the cluster.
  # It gets no further than the object on its own — a running container keeps the
  # environment it started with, so a rotation only reaches a pod when that pod is
  # replaced (`kubectl rollout restart`, or the next `make deploy`).
  printf '%s\n' "$rendered" | kubectl apply -f -
  echo "rendered $target in namespace '$namespace' (${#literal_args[@]} args)" >&2
done
