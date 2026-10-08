#!/usr/bin/env bash
# The restore drill (PLAN.md M9): read a nightly `pg_dump` back with `pg_restore`,
# into a throwaway database in the same cluster, and compare what it holds with
# what the live database holds.
#
# Why this is a command and not a paragraph: a backup that has never been read is
# a hope, not a recovery path. M4's CronJob writes archives and verifies they are
# not empty; nothing until now has proved one can be turned back into a database.
# The first time an archive is read should not be the time it is needed.
#
# What the drill deliberately avoids:
#   * Restoring into the live database. A drill that can break production is a
#     drill nobody runs twice.
#   * Any network from the pod. The archive is copied in with `kubectl cp`,
#     because these pods have no internet egress (AGENTS.md, "Network") and a
#     drill that needed it would be a second thing to debug.
#   * Reading the bucket with the backup identity. It holds `storage.objectCreator`
#     only — it can write a dump and cannot list the bucket back. Reading is a
#     human act, by design (gcp/database.tf).
#
# Usage: scripts/restore-drill.sh [namespace] [gs://object]
#   object defaults to the newest archive in `gs://<pgdump bucket>`.
set -euo pipefail

ns="${1:-learn-anything}"
bucket="${DUMP_BUCKET:-$(terraform -chdir="$(cd "$(dirname "$0")/.." && pwd)/gcp" output -raw pgdump_bucket 2>/dev/null)}"
scratch_db=drill
image="$(kubectl get statefulset/learn-anything-db -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ -n "$image" ] || { echo "could not read the database image from statefulset/learn-anything-db" >&2; exit 1; }
run="restore-drill-$(date -u +%Y%m%d-%H%M%S)"
local_dump="$(mktemp -d)/archive.sql.gz"
trap 'rm -rf "$(dirname "$local_dump")"; kubectl delete pod "$run" -n "$ns" --wait=false >/dev/null 2>&1 || true' EXIT

archive="${2:-$(gcloud storage ls "gs://$bucket/*.sql.gz" 2>/dev/null | sort | tail -1)}"
[ -n "$archive" ] || { echo "no .sql.gz archives in gs://$bucket — the backup CronJob has not produced one yet" >&2; exit 1; }

echo "archive:   $archive"
echo "scratch:   pod $run, image $image, database $scratch_db"

# A pod, not a Job: this is a temporary interactive database, and the teardown is
# the trap above rather than a cleanup Job that could be skipped.
kubectl run "$run" -n "$ns" --image="$image" --restart=Never \
  --overrides="{\"spec\":{\"containers\":[{\"name\":\"$run\",\"image\":\"$image\",\"command\":[\"sh\",\"-c\",\"exec docker-entrypoint.sh postgres\"],\"env\":[{\"name\":\"POSTGRES_PASSWORD\",\"value\":\"drill-not-a-secret\"},{\"name\":\"POSTGRES_DB\",\"value\":\"$scratch_db\"}]}]}}" \
  >/dev/null
kubectl wait --for=condition=Ready "pod/$run" -n "$ns" --timeout=180s >/dev/null

gcloud storage cp "$archive" "$local_dump" >/dev/null 2>&1
kubectl cp "$local_dump" "$ns/$run:/tmp/archive.sql.gz"

echo "restoring…"
started=$(date +%s)
# `--no-owner --no-privileges` mirrors how the dump was written; a restore that
# insists on the original roles would fail on a cluster where they do not exist,
# which is exactly the wrong lesson to learn during an emergency.
# `-U postgres`, not the default: `kubectl exec` lands as root, and the image's superuser
    # is `postgres`. Guessing that from a "role \"root\" does not exist" error is a
    # half-minute well spent once and never again.
    if ! kubectl exec "$run" -n "$ns" -- pg_restore --no-owner --no-privileges -U postgres --dbname="$scratch_db" /tmp/archive.sql.gz; then
  echo "pg_restore reported errors (above). A partial restore is still information; treat it as a failure until you know why."
fi
echo "restored in $(( $(date +%s) - started ))s"

# Side-by-side row counts. `n_live_tup` is an estimate, and it is the same
# estimate on both sides, which is what makes the comparison meaningful; the point
# is "the archive contains the tables and roughly the rows", not a checksum.
counts() {
  # live target uses the app role; the scratch pod only has the image superuser.
  kubectl exec "$1" -n "$ns" -- psql -U "$3" -d "$2" -Atc \
    "select relname||' '||coalesce(n_live_tup,0) from pg_stat_user_tables order by relname" 2>/dev/null
}
live="$(counts statefulset/learn-anything-db learn_anything learn)"
restored="$(counts "$run" "$scratch_db" postgres)"

if [ -z "$restored" ]; then
  echo "the restored database has no user tables: the archive restored nothing usable."
  exit 1
fi

printf '%-34s %8s %8s\n' "table" "live" "archive"
join -a1 -a2 -e '-' -o '0,1.2,2.2' \
  <(printf '%s\n' "$live" | sort) <(printf '%s\n' "$restored" | sort) |
  awk '{printf "%-34s %8s %8s%s\n", $1, $2, $3, ($2==$3?"":"   <- differs")}'

live_tables=$(printf '%s\n' "$live" | grep -c . || true)
restored_tables=$(printf '%s\n' "$restored" | grep -c . || true)
echo
echo "tables: live $live_tables, from the archive $restored_tables"
if [ "$live_tables" = "$restored_tables" ]; then
  echo "the archive restores to a database with the same shape as the live one"
else
  echo "shape mismatch — the archive is not the database you think it is"
  exit 1
fi
# A count difference is not automatically a loss: the archive is a snapshot at the
# time in its name, and the live database has kept living since then. Saying so
# next to the numbers is what keeps "differs" from being misread as corruption.
echo "archive snapshot: ${archive##*/}  (live counts are current, so any writes since that time will differ)"
echo "tearing down $run"
