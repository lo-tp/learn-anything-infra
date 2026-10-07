#!/usr/bin/env bash
# Is the public surface the one this repo says it is?
#
# Four things have to agree for `https://api.lotp.xyz` to work, and three of them
# are edited by hand or by a controller rather than by `make deploy`:
#
#   the host list Terraform declares  (gcp/ingress.tf, variables.tf)
#   the host list the Ingress and certificate carry  (manifests/overlays/prod)
#   the records at the registrar        (typed by hand — ADR 0004)
#   the certificate Google actually issued  (a controller, on its own schedule)
#
# Any one of them being behind the others looks identical from a browser: a
# connection error at a URL that a `git log` says is deployed. So this asks each
# one out loud and exits non-zero if they disagree. Run it after a deploy, and
# before concluding that a failure is the code's.
#
# It reads the *live* Ingress and certificate rather than the rendered YAML: the
# thing that drifts is what the cluster is running, and an undeployed change shows
# up as a host the live object does not have.
set -euo pipefail

ns="${NAMESPACE:-learn-anything}"
ingress="${INGRESS_NAME:-surfaces}"
cert="${CERT_NAME:-learn-anything-tls}"

if [ -f Makefile ] && [ -f gcp/variables.tf ]; then root=gcp; else root=../gcp; fi
tfenv() { GOOGLE_APPLICATION_CREDENTIALS="${GCRED:-$HOME/.config/gcp/learn-anything-510905.json}" terraform -chdir="$root" output "$@"; }
tf() { tfenv -raw "$1"; }
# -raw only takes primitives; the host list is a list, so it comes as JSON and is
# printed by python rather than by terraform.
tf_json() { tfenv -json "$1"; }

declared_ip="$(tf ingress_ip)"
json="$(tf_json certificate_hosts)"
# Terraform hands a list out as JSON; every comparison below is line-per-host, so
# it is flattened once here rather than in four places.
hosts_list="$(printf '%s' "$json" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')"

fail=0
note() { printf '  %-26s %s\n' "$1" "$2"; }

echo "Terraform says the address is $declared_ip and these hosts exist:"
printf '%s\n' "$hosts_list" | sed 's/^/  /'

# ── 1. what the cluster is configured to route, and what its certificate lists ─
live_hosts="$(kubectl -n "$ns" get ingress "$ingress" -o json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(r["host"] for r in d.get("spec",{}).get("rules",[])))' 2>/dev/null || true)"
cert_domains="$(kubectl -n "$ns" get managedcertificate "$cert" -o json 2>/dev/null \
  | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("spec",{}).get("domains",[])))' 2>/dev/null || true)"
cert_status="$(kubectl -n "$ns" get managedcertificate "$cert" -o jsonpath='{.status.certificateStatus}' 2>/dev/null || true)"

compare() {
  local what="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "  $what: matches Terraform ($(printf '%s\n' "$want" | sed '/^$/d' | wc -l | tr -d ' ') hosts)"
  else
    fail=1
    echo "  $what: DIFFERS from Terraform"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/      /' || true
  fi
}

echo
echo "The cluster:"
compare "ingress rules" "$live_hosts" "$hosts_list"
compare "certificate domains" "$cert_domains" "$hosts_list"
echo "  managed certificate: ${cert_status:-MISSING (no ManagedCertificate object?)}"

# ── 2. the registrar ───────────────────────────────────────────────────────────
echo
echo "DNS (what the registrar answers today):"
while read -r host; do
  [ -n "$host" ] || continue
  got="$(dig +short "$host" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
  if [ -z "$got" ]; then
    printf '  %-26s NO RECORD (typed at the registrar?  terraform output -raw dns_records)\n' "$host"; fail=1
  elif [ "$got" != "$declared_ip" ]; then
    printf '  %-26s %s — expected %s\n' "$host" "$got" "$declared_ip"; fail=1
  else
    printf '  %-26s %s\n' "$host" "$got"
  fi
done < <(printf '%s\n' "$hosts_list")

# ── 3. the certificate a browser would be shown ────────────────────────────────
echo
echo "TLS (does the presented certificate cover the name?):"
while read -r host; do
  [ -n "$host" ] || continue
  # `-ext subjectAltName` is an OpenSSL 1.1.1+ flag and macOS ships LibreSSL, which
  # answers "unknown option" — a probe like this one has to degrade to no output
  # rather than to an error that looks like a missing certificate.
  san="$(openssl s_client -servername "$host" -connect "$host:443" </dev/null 2>/dev/null \
    | openssl x509 -noout -text 2>/dev/null \
    | awk '/Subject Alternative Name/{getline; print}' | tr ',' '\n' | grep -o "DNS:[^ ]*" || true)"
  if printf '%s' "$san" | grep -q "DNS:$host"; then
    printf '  %-26s certificate covers it\n' "$host"
  elif [ -z "$san" ]; then
    printf '  %-26s no certificate on 443 yet (Google issues once the records resolve)\n' "$host"; fail=1
  else
    printf '  %-26s certificate does NOT list this name (%s)\n' "$host" "$(printf '%s' "$san" | tr '\n' ' ')"; fail=1
  fi
done < <(printf '%s\n' "$hosts_list")

echo
echo "Rows that belong at the registrar (this repo is the source of truth):"
tf dns_records
echo
echo "On the zone but not ours — leave alone:"
tf dns_records_foreign

exit $fail
