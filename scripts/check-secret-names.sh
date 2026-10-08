#!/usr/bin/env bash
# Keep the two lists of Secret names in step: the one Terraform creates
# (`gcp/app_secrets.tf`) and the one scripts/render-secrets.sh maps into cluster
# Secrets. Both are in this repository, which is the convenience; the cost is that
# they can disagree without anything failing, and the disagreement shows up as a pod
# that starts and then cannot talk to the LLM.
#
# Fatal when the renderer asks for a name Terraform does not create — that is a
# reference to something that cannot exist. Informational when Terraform creates a
# name the renderer never uses, because some entries are consumed elsewhere on
# purpose (`pgdump-service-account-key` is handed to the backup workload as a
# mounted file, not as an environment variable).
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)"
# The backend is configured inside gcp/backend.tf (its bucket is printed by the
# bootstrap root), so this needs no -backend flag: init here is a no-op on a
# machine that has planned before, and correct on one that has not.
terraform -chdir="$dir/gcp" init -input=false >/dev/null
created="$(terraform -chdir="$dir/gcp" output -json secret_names |
  python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')"

requested="$(python3 - "$dir/scripts/render-secrets.sh" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
names = set()
for m in re.finditer(r'^\s*\[[a-z-]+\]="([^"]+)"', text, re.M):
    names |= {p.split("=", 1)[1] for p in m.group(1).split()}
m = re.search(r'^OPTIONAL_pairs="([^"]+)"', text, re.M)
if m:
    names |= {p.split("=", 1)[1] for p in m.group(1).split()}
m = re.search(r'^DB_PASSWORD_SECRET=(\S+)', text, re.M)
if m:
    names.add(m.group(1))
print("\n".join(sorted(names)))
PY
)"

echo "Terraform creates $(printf '%s\n' "$created" | wc -l | tr -d ' ') application secrets; the renderer references $(printf '%s\n' "$requested" | wc -l | tr -d ' ')."

fail=0
for name in $requested; do
  if ! printf '%s\n' "$created" | grep -qx "$name"; then
    echo "  $name: referenced by render-secrets.sh, not created by Terraform"
    fail=1
  fi
done
for name in $created; do
  if ! printf '%s\n' "$requested" | grep -qx "$name"; then
    echo "  $name: created by Terraform, not read by the renderer (fine if something else consumes it)"
  fi
done

if [ "$fail" = 0 ]; then
  echo "the renderer only asks for names Terraform creates"
else
  echo "fix the mapping or the Terraform for_each; do not fix it by writing a value into a manifest"
fi
exit "$fail"
