#!/usr/bin/env bash
# Resolve the Google Cloud project id, in an order chosen for what fails.
#
# 1. PROJECT_ID, if the caller set it. An explicit value always wins: it is how CI
#    says what it is in, and how a person overrides a run.
# 2. gcp/terraform.tfvars — the value *this repository declares*. Offline,
#    deterministic, no network. The repo is the source of truth for this project's
#    configuration, so the declared value is the right default for a read.
# 3. `terraform output -raw project_id` — what is actually applied. Kept as the
#    fallback rather than the first choice, because it is the only step that needs
#    the state bucket, and the state bucket is behind a proxy from this machine.
#
# Why the order matters: the Makefile used to run step 3 once, at parse time, with
# `2>/dev/null`. When the proxy hiccuped, PROJECT_ID became the empty string, and
# every consumer then reported its own confusing failure — a script's "PROJECT_ID
# must be set", or worse, a check that read that failure as an answer. A value that
# cannot be resolved must say so, once, in these words.
#
# Nothing here decides whether the declared and applied values agree: that is
# `make tf-plan`'s job, and it is a different question from "which project am I in".

set -euo pipefail

if [ -n "${PROJECT_ID:-}" ]; then
  printf '%s\n' "$PROJECT_ID"
  exit 0
fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tfvars="${1:-$here/../gcp/terraform.tfvars}"

if [ -f "$tfvars" ]; then
  declared=$(sed -n 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$tfvars" | head -1)
  if [ -n "$declared" ]; then
    printf '%s\n' "$declared"
    exit 0
  fi
fi

# The declared value was not readable. Try the state, and name what a failure there
# is about: that call needs both the proxy (from mainland China the storage endpoint is
# reachable but the API used for the backend is not always) and service-account
# credentials. The credential path matches the Makefile's GCRED default, so a laptop
# that is configured the way this repository documents needs no extra setting here.
if [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "${HOME}/.config/gcp/learn-anything-510905.json" ]; then
  export GOOGLE_APPLICATION_CREDENTIALS="${HOME}/.config/gcp/learn-anything-510905.json"
fi
if resolved=$(terraform -chdir="$here/../gcp" output -raw project_id 2>/dev/null) && [ -n "$resolved" ]; then
  printf '%s\n' "$resolved"
  exit 0
fi

{
  echo "cannot resolve the project id:" >&2
  echo "  PROJECT_ID is unset," >&2
  echo "  no project_id in $tfvars," >&2
  echo "  and 'terraform -chdir=gcp output -raw project_id' failed. That call needs the local"
  echo "   proxy (HTTPS_PROXY/HTTP_PROXY — `make tf-*` sets them) and service-account"
  echo "   credentials (GOOGLE_APPLICATION_CREDENTIALS, or the file at"
  echo "   \$HOME/.config/gcp/learn-anything-510905.json)." >&2
}
exit 1
