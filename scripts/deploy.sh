#!/usr/bin/env bash
#
# deploy.sh — the order a deploy has to happen in.
#
#   1. read the image the overlay says it will deploy;
#   2. run that image's migrations as a Job and wait for it;
#   3. only then apply the workloads, and only then wait for the rollout.
#
# The order is the milestone: a failed migration stops here, with the Job's log
# printed, and nothing under the workloads has been touched — so whatever was
# serving before keeps serving (docs/plan/m05-migrations-as-a-gate.md). This is not an atomic transaction and
# does not pretend to be: it is a gate with one failure mode, deliberately placed
# where a human can read the reason.
#
# Nothing here re-decides what is deployed. The image reference comes out of
# manifests/overlays/<env>/kustomization.yaml, so the Job provably runs the same
# image the Deployment is about to run — one source, no argument that can drift
# from it.
#
# Usage:
#   NAMESPACE=learn-anything scripts/deploy.sh prod
#
# Run by `make deploy` (human identity via make kcreds) and by
# .github/workflows/deploy.yml (application default credentials via
# scripts/ci-kubeconfig.sh). Nothing in here depends on which; that is the point of
# M7 — the order is the contract, the identity is a detail.
set -euo pipefail

environment="${1:-prod}"
namespace="${NAMESPACE:-}"
overlay="manifests/overlays/${environment}"
rollout_timeout="${ROLLOUT_TIMEOUT:-300s}"
job_timeout="${JOB_TIMEOUT:-900s}"

case "$environment" in
  prod)    [ -n "$namespace" ] || namespace=learn-anything ;;
  staging) [ -n "$namespace" ] || namespace=staging ;;
esac
[ -d "$overlay" ] || { echo "no such overlay: $overlay" >&2; exit 2; }
[ -n "$namespace" ] || { echo "NAMESPACE is required for environment '$environment'" >&2; exit 2; }

k() { kubectl -n "$namespace" "$@"; }

render() { kubectl kustomize "$overlay"; }

# The backend's image, as the overlay will apply it. If this ever finds two or
# zero, that is a real change in the manifests and worth failing loudly about.
images=$(render | awk '$1 == "image:" && $2 ~ /learn-anything-backend/ {print $2}' | sort -u)
count=$(printf '%s\n' "$images" | grep -c . || true)
if [ "$count" -ne 1 ]; then
  echo "expected exactly one backend image in $overlay, found $count:" >&2
  printf '%s\n' "$images" >&2
  exit 1
fi
image=$(printf '%s\n' "$images" | head -1)

# The name has to change whenever the thing that runs changes, because a Job's pod
# template is immutable: same name + different template is an API rejection, not an
# update. Two things can change it — the image, and this Job's own definition — so
# the name is derived from both: <image digest, 12 hex>-<hash of the substituted
# template, 6 hex>. A tag is allowed (a local build has one) but is called out,
# because then the first half is a claim the registry may not honour.
if [[ "$image" == *@* ]]; then
  digest=${image##*@}; digest=${digest#sha256:}
  idpart="${digest:0:12}"
else
  idpart=$(printf '%s' "${image##*:}" | tr -c 'a-z0-9' '-' | sed 's/^-*//;s/-*$//' | cut -c1-12)
  echo "note: deploying '$image' by tag, not digest — the tag can move under a later deploy" >&2
fi

hasher() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; }
job_body=$(sed -e "s/__JOB_NAME__/migrate/g" -e "s|__IMAGE__|${image}|g" manifests/migrate/job.yaml)
tplpart=$(printf '%s' "$job_body" | hasher | cut -c1-6)
job="migrate-${idpart}-${tplpart}"

echo "==> environment=$environment namespace=$namespace"
echo "==> image=$image"

if [ "${SKIP_MIGRATE:-0}" = "1" ]; then
  # Staging's database is deliberately asleep (overlays/staging/database-zero.yaml),
  # so a migration there would fail on a connection with no endpoint behind it.
  # Waking the database is the honest answer; this switch is for when someone is
  # deploying manifests and does not need the gate.
  echo "!! SKIP_MIGRATE=1: the schema is NOT being checked; the workloads are being applied as they are" >&2
else
  echo "==> migration job: $job"
  # `-n` here matters and is easy to lose: the Job template has no namespace of
  # its own (unlike the overlay, whose kustomization sets one), so an apply without
  # it puts a migration in the default namespace where nothing is looking.
  #
  # A Job that already ran is neither re-applied nor re-run. The API reason: that
  # Job's pod template is immutable, and GKE's own defaults (dropping NET_RAW) make
  # even an unchanged file differ from the stored object — so re-applying it is an
  # immutability error, not a no-op, and the deploy would die on a detail nobody
  # changed. The other reason is what a deploy means: re-running a migration that
  # completed buys nothing, and re-running one that failed would pretend the failure
  # was transient, which a schema error is not.
  ran=$(k get "job/${job}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
  if [ "${ran:-0}" -ge 1 ]; then
    echo "==> migration Job ${job} already completed; not re-running it"
  elif k get "job/${job}" >/dev/null 2>&1; then
    echo "MIGRATION ALREADY FAILED for this image and definition. Nothing was applied. Fix the migration or the code, then deploy a new image." >&2
    k logs "job/${job}" --all-containers --prefix >&2 || true
    exit 1
  else
    printf '%s' "$job_body" | sed "s/^  name: migrate$/  name: ${job}/" | k apply -f -
  fi

  if ! k wait --for=condition=complete "job/${job}" --timeout="$job_timeout"; then
    echo
    echo "MIGRATION FAILED — nothing else was applied, so the running workloads are unchanged." >&2
    k get "job/${job}" -o wide || true
    echo "--- migration log ---" >&2
    k logs "job/${job}" --all-containers --prefix || true
    echo "-----------------------" >&2
    exit 1
  fi
  echo "==> migration complete"
fi

echo "==> applying $overlay"
render | kubectl apply -f -

echo "==> waiting for the backend rollout"
k rollout status deployment/backend --timeout="$rollout_timeout"

echo "==> state"
k get deploy,sts,cronjob,job -o wide | sed -n '1,20p'
k get pods -o wide | sed -n '1,20p'
