#!/usr/bin/env bash
# M7's gate, as a command: prove where the secret values are *not*, and that the
# pairs shared between services are the same value.
#
# Two claims, both worth running rather than asserting:
#
#   1. No secret value appears in a repository, in an image, or in a manifest.
#      This repo declares which Secret Manager entries exist; it never holds a
#      value. The images are built from working trees that could have had a
#      committed `.env`, so "check the image you are running" is a stronger test
#      than "check the Dockerfile".
#   2. The shared pairs match. `JWT_SECRET` (backend and frontend) and
#      `SANDBOX_SERVICE_TOKEN` (backend and sandbox) are one value each, read by
#      two services. A mismatch is invisible at deploy time and appears later as
#      401s at sign-in and at `/slides/{id}` — which is why this compares what the
#      **running containers** hold, not what the manifest says.
#
# Nothing here prints a value. Everything compared is a hash, because a log line
# with a secret in it is how a secret ends up in a log retention policy.
#
# Usage: scripts/secret-hygiene.sh [namespace]
set -euo pipefail

ns="${1:-learn-anything}"
project="${PROJECT_ID:?PROJECT_ID must be set}"

# The repositories this product is made of. Absolute paths on purpose: this is a
# cross-repo claim, and a relative path would quietly check less than it says. The
# default is derived — the directory that contains this repo — because an absolute
# path baked into a tracked file is a fact about one laptop. A repository that is
# not checked out is reported as "not present, not checked", never skipped quietly.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # <repo>/scripts
repo_root="${REPO_ROOT:-$(dirname "$(dirname "$here")")}"  # the directory holding the repos
repos=(
  "$repo_root/learn-anything-infra"
  "$repo_root/python/learn-anything-backend"
  "$repo_root/javascript/learn-anything"
  "$repo_root/javascript/learn-anything-sandbox"
)

# Where to look inside each pod for a value that was baked into an image instead of
# handed to the process at runtime. These are the app trees, not the whole
# filesystem: scanning / would take longer than the rest of this script combined
# and would find nothing the app tree could miss.
image_paths=(
  "backend|/app"
  "frontend|/app/.next /app/messages"
  "sandbox|/app/.next /app/out /app/core"
)

# The pairs that must agree, and the workload that holds each half.
pairs=(
  "JWT_SECRET|backend|frontend"
  "SANDBOX_SERVICE_TOKEN|backend|sandbox"
)

# Entries whose value belongs to a later milestone. `openai-api-key`,
# `openai-base-url` and `llm-model` are declared now (M1) and filled at M8, when
# the real LLM is switched on; everything else must be real today.
expected_later=(openai-api-key openai-base-url llm-model)

fail=0
sha() { printf '%s' "$1" | sha256sum | cut -c1-16; }
secret_value() {
  gcloud secrets versions access latest --secret="$1" --project="$project" 2>/dev/null || true
}

echo "1. Every Secret Manager entry this project declares, and whether it is real:"
for name in $(gcloud secrets list --project="$project" --format='value(name)' 2>/dev/null); do
  value="$(secret_value "$name")"
  later=0
  for l in "${expected_later[@]}"; do [ "$name" = "$l" ] && later=1; done
  case "$value" in
    "" )
      if [ "$later" = 1 ]; then echo "  $name: empty, supplied at M8"; continue; fi
      echo "  $name: EMPTY (M7 requires it)"; fail=1; continue ;;
    REPLACE_ME*)
      if [ "$later" = 1 ]; then echo "  $name: placeholder, supplied at M8"; continue; fi
      echo "  $name: placeholder (M7 requires it)"; fail=1; continue ;;
  esac
  echo "  $name: present (${#value} chars, hash $(sha "$value"))"

  echo "    repositories:"
  for repo in "${repos[@]}"; do
    [ -d "$repo/.git" ] || { echo "      $(basename "$repo"): not present, not checked"; continue; }
    if git -C "$repo" grep -qF -- "$value" 2>/dev/null; then
      hit="$(git -C "$repo" grep -lF -- "$value" | head -3 | tr '\n' ' ')"
      echo "      $(basename "$repo"): FOUND in $hit"; fail=1
    else
      echo "      $(basename "$repo"): clean"
    fi
  done

  echo "    images (the running ones, not the Dockerfiles):"
  for entry in "${image_paths[@]}"; do
    workload="${entry%%|*}"; paths="${entry#*|}"
    pod="$(kubectl get pod -n "$ns" -l "app.kubernetes.io/name=$workload" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$pod" ]; then echo "      $workload: no pod running, not checked"; continue; fi
    found="$(kubectl exec -n "$ns" "$pod" -- sh -c \
      "grep -rlF -- '$value' $paths 2>/dev/null | head -2" 2>/dev/null || true)"
    if [ -n "$found" ]; then
      echo "      $workload: BAKED INTO THE IMAGE: $(printf '%s' "$found" | tr '\n' ' ')"; fail=1
    else
      echo "      $workload: not in $paths"
    fi
  done
done

echo
echo "2. The pairs that must be one value, compared as the containers hold them:"
# No associative arrays here: /bin/bash on macOS is 3.2, where `declare -A` is a
# parse error, and this script has to run on the laptop it was written on.
for pair in "${pairs[@]}"; do
  key="${pair%%|*}"; rest="${pair#*|}"; left="${rest%%|*}"; right="${rest#*|}"
  a=""; b=""
  for side in left right; do
    workload="${!side}"
    pod="$(kubectl get pod -n "$ns" -l "app.kubernetes.io/name=$workload" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$pod" ]; then echo "  $key / $workload: no pod running — cannot compare"; fail=1; continue; fi
    value="$(kubectl exec -n "$ns" "$pod" -- printenv "$key" 2>/dev/null || true)"
    if [ -z "$value" ]; then echo "  $key / $workload: not in the environment"; fail=1; continue; fi
    if [ "$side" = left ]; then a="$(sha "$value")"; else b="$(sha "$value")"; fi
  done
  declared="$(sha "$(secret_value "$(echo "$key" | tr 'A-Z' 'a-z' | tr '_' '-')")")"
  if [ -n "$a" ] && [ "$a" = "$b" ]; then
    if [ -n "$declared" ] && [ "$declared" != "$a" ]; then
      echo "  $key: $left and $right agree ($a), but that is not what Secret Manager holds ($declared) — the pods are running an older render"
      fail=1
    else
      echo "  $key: $left == $right == Secret Manager ($a)"
    fi
  else
    echo "  $key: MISMATCH ($left=${a:-none} $right=${b:-none}) — expect 401s at sign-in and /slides/{id}"
    fail=1
  fi
done

echo
if [ "$fail" = 0 ]; then
  echo "clean: no value in a repository or an image, and both shared pairs match"
else
  echo "see the lines above marked FOUND / BAKED / MISMATCH / EMPTY"
fi
exit "$fail"
