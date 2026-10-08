#!/usr/bin/env python3
"""M10: read what the platform actually costs, from Google's own numbers.

The plan is full of estimates and says so. This is the thing that replaces them:
the BigQuery billing export, queried for the current period, broken down by service
and SKU, with credits reported separately from cost.

Two facts this encodes rather than discovers each time:

* **Cost and credits are different numbers.** The trial credit makes the invoice
  small; it does not make the platform cheap. Anything that reads only the net
  figure will look fine until 2027-01-06 and then change all at once. So `cost`
  and `credits` are printed side by side, and the daily rate that is compared
  against the $3.30/day ceiling is computed from **cost**.
* **Billing data lags.** Google's export updates on a delay of hours to a day or
  more, and the current month is incomplete. A figure read on day one of a
  cluster's life measures one day of running and calls it a month. The report
  prints the window it actually covered, so the arithmetic cannot be laundered.

If the export does not exist, this exits 2 with the console steps — that setup is
a one-time human act (Billing → Budgets & costs → Billing export → BigQuery
usage export), like the DNS records, and this repo declares it instead of
performing it.

It reads a **human** gcloud access token (`gcloud auth print-access-token`), like
every other cost/cluster reading target; Terraform's service-account key is not
used here. `make cost-report` runs it with the bundled SDK on PATH; running the
file directly needs that PATH too, or `GCLOUD=` pointing at a gcloud binary.

Usage: scripts/cost-report.py [--project P] [--days N] [--dataset D] [--sku-grep S]
"""

from __future__ import annotations
import argparse, datetime, json, os, shutil, subprocess, sys, urllib.error, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLOUDSDK = os.environ.get("CLOUDSDK_CORE_PROJECT") or "learn-anything-510905"
GKE_SERVICE = "services/6F81-A0F9-337E"  # Kubernetes Engine, from the Billing Catalog API


def gcloud_bin() -> str:
    """Find gcloud. The SDK ships in this working tree (AGENTS.md, 'Cluster
    access'), so a direct `python3 scripts/cost-report.py` need not die on a
    bare-name lookup: the last candidate is that documented path. An explicit
    `GCLOUD=` is an assertion, not a hint — if it names nothing executable, say
    so instead of quietly using a different binary.
    """
    explicit = os.environ.get("GCLOUD")
    if explicit:
        if os.access(explicit, os.X_OK):
            return explicit
        sys.exit(f"GCLOUD={explicit} is not an executable file.")
    found = shutil.which("gcloud")
    if found:
        return found
    bundled = os.path.join(REPO, "google-cloud-sdk", "bin", "gcloud")
    if os.access(bundled, os.X_OK):
        return bundled
    sys.exit(
        "gcloud not found.\n  use `make cost-report` (it puts the bundled SDK on PATH), or\n"
        "  export GCLOUD=/path/to/gcloud, or install the Google Cloud SDK."
    )


def token() -> str:
    out = subprocess.run([gcloud_bin(), "auth", "print-access-token"], capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        detail = (out.stderr.strip() + "\n" + out.stdout.strip()).strip()[:400]
        print(f"{gcloud_bin()} auth print-access-token failed:\n  {detail}")
        low = detail.lower()
        if "credential" in low or "not signed in" in low or "unauthorized" in low:
            print(
                "  sign in with `gcloud auth login` — not `gcloud auth application-default login`,\n"
                "  which would repoint Terraform at this human identity (AGENTS.md, 'Cluster access')."
            )
        else:
            print("  this is gcloud itself failing, not an absent credential: fix what it reports above.")
        sys.exit(2)
    if not out.stdout.strip():
        # Exit 0 and no token: gcloud can print a warning to stdout and still give
        # us nothing. Sending `Bearer ` to BigQuery answers 401 with a JSON blob,
        # which reads like a permissions problem rather than an absent credential.
        print("gcloud answered but returned no access token.")
        print(
            "  sign in with `gcloud auth login` — not `gcloud auth application-default login`,\n"
            "  which would repoint Terraform at this human identity (AGENTS.md, 'Cluster access')."
        )
        sys.exit(2)
    return out.stdout.strip()


def api(method: str, url: str, tok: str, payload: dict | None = None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("authorization", f"Bearer {tok}")
    if data:
        req.add_header("content-type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url}\n  HTTP {e.code}: {e.read().decode('utf-8','replace')[:300]}")
    except urllib.error.URLError as e:
        # The signature of this network, not a bug in this script: some Google
        # endpoints black-hole rather than refuse (AGENTS.md, "Network").
        sys.exit(
            f"{method} {url}\n  {e.reason} — this endpoint did not answer, which on this machine\n"
            "  usually means the request did not go through the local proxy. Use `make cost-report`,\n"
            "  or export HTTPS_PROXY/HTTP_PROXY as its output shows."
        )


def find_dataset(tok: str, project: str, explicit: str | None) -> tuple[str, str]:
    """Return (dataset_id, table_id) for the billing export."""
    if explicit:
        dataset = explicit
    else:
        d = api("GET", f"https://bigquery.googleapis.com/bigquery/v2/projects/{project}/datasets", tok)
        cands = [x["id"].split(".")[-1] for x in d.get("datasets", []) if "billing_export" in x["id"]]
        if not cands:
            print(
                "No BigQuery billing export exists in this project.\n"
                "  Enable it once, in the console: Billing → Budgets & costs → Billing export →\n"
                "  'BigQuery usage export' → this project. It creates a dataset named\n"
                "  gcp_billing_export_v1_<BILLING_ACCOUNT>, and it starts exporting from that\n"
                "  moment: history before the enablement is not backfilled, so the sooner it is\n"
                "  on, the shorter the blind spot. (AGENTS.md lists the things Terraform does not\n"
                "  own; this is one of them.)"
            )
            sys.exit(2)
        dataset = cands[0]
    tables = api("GET", f"https://bigquery.googleapis.com/bigquery/v2/projects/{project}/datasets/{dataset}/tables", tok)
    names = [t["id"].split(".")[-1] for t in tables.get("tables", [])]
    if not names:
        sys.exit(f"dataset {dataset} has no tables yet — the export has not written anything (it lags by hours).")
    return dataset, names[0]


def query(tok: str, project: str, table: str, days: int) -> list[dict]:
    start = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    sql = f"""
      SELECT service.description AS service, service.id AS service_id,
             sku.description AS sku, sku.id AS sku_id,
             COUNT(*) AS rows,
             SUM(cost) AS cost,
             SUM(COALESCE(credits.amount, 0)) AS credits,
             SUM(usage.amount) AS usage_amount, ANY_VALUE(usage.unit) AS usage_unit
      FROM `{table}`
      WHERE cost > 0 OR ABS(COALESCE(credits.amount,0)) > 0
      GROUP BY service.description, service.id, sku.description, sku.id
      ORDER BY cost DESC
    """
    # The export dataset lives in a multi-region/US location; a job created in the
    # wrong one fails with "not found", which looks like a missing table.
    body = {"query": sql, "useLegacySql": False, "maxResults": 200,
            "jobReference": {"projectId": project, "location": os.environ.get("BQ_LOCATION", "US")}}
    r = api("POST", f"https://bigquery.googleapis.com/bigquery/v2/projects/{project}/queries", tok, body)
    if not r.get("jobComplete", True):
        sys.exit("query still running; re-run (or raise the timeout).")
    return [dict(zip([c["name"] for c in r["schema"]["fields"]],
                     [v.get("v") for v in row["f"]])) for row in r.get("rows", [])]


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--project", default=CLOUDSDK)
    p.add_argument("--days", type=int, default=30, help="look back N days (default 30)")
    p.add_argument("--dataset", help="explicit dataset id, if it is not in this project")
    p.add_argument("--sku-grep", default="", help="highlight SKUs matching this substring")
    args = p.parse_args()

    tok = token()
    dataset, table_name = find_dataset(tok, args.project, args.dataset)
    table = f"{args.project}.{dataset}.{table_name}"
    print(f"source: {table}")
    print(f"window: the export rows Google has for the last {args.days} days; billing data lags by hours to a day\n")

    rows = query(tok, args.project, table, args.days)
    if not rows:
        print("the export has no rows yet — wait for it to write (it is not backfilled).")
        return 2

    cost_total = sum(float(r["cost"] or 0) for r in rows)
    credit_total = sum(float(r["credits"] or 0) for r in rows)

    print(f"{'service':<34} {'sku':<44} {'cost':>9} {'credits':>10}")
    print("-" * 101)
    for r in rows:
        mark = "  <<" if args.sku_grep and args.sku_grep.lower() in (r["sku"] or "").lower() else ""
        print(f"{(r['service'] or '')[:33]:<34} {(r['sku'] or '')[:43]:<44} "
              f"{float(r['cost'] or 0):>9.4f} {float(r['credits'] or 0):>10.4f}{mark}")

    print("-" * 101)
    print(f"{'total':<79}{cost_total:>9.4f} {credit_total:>10.4f}")
    print(f"\ncost            ${cost_total:8.2f}   (what the platform charges)")
    print(f"credits         ${-credit_total:8.2f}   (what Google is paying for you)")
    print(f"net             ${cost_total + credit_total:8.2f}   (what the invoice says)")
    print(f"per day         ${cost_total / max(args.days, 1):8.2f}   against the ceiling of $3.30/day")
    print(f"\ncost by service:")
    by_service: dict[str, float] = {}
    for r in rows:
        key = r["service"] or r["service_id"] or "?"
        by_service[key] = by_service.get(key, 0.0) + float(r["cost"] or 0)
    for name, cost in sorted(by_service.items(), key=lambda kv: -kv[1]):
        print(f"  {name:<38} ${cost:8.2f}  {100*cost/cost_total if cost_total else 0:5.1f}%")

    gke = [r for r in rows if (r.get("service_id") or "").endswith(GKE_SERVICE.split("/")[-1])]
    fee = [r for r in gke if "cluster" in (r["sku"] or "").lower() or "management" in (r["sku"] or "").lower()]
    print("\nthe named M10 question — is a GKE cluster-management fee being charged?")
    if not gke:
        print("  no Kubernetes Engine rows at all: either the export predates the cluster, or the service id changed.")
    elif fee:
        for r in fee:
            print(f"  {r['sku']}: ${float(r['cost'] or 0):.4f}")
    else:
        print("  no cluster-management SKU appears in the export. GKE lines that do appear:")
        for r in gke[:6]:
            print(f"    {r['sku']}  ${float(r['cost'] or 0):.4f}")
    print("\nThis is the number the plan's cost tables are replaced by. Treat a window shorter than a\n"
          "few days as a rate sample, not a bill.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
