# M10 — Verify the budget claim with numbers

← [plan index](./index.md) · [M9](./m09-cutover-then-render-goes-away.md)

The clock is fixed, so this is arithmetic rather than a feeling. Against
**$3.30/day until 2027-01-06**, read the billed figure at three checkpoints and
commit the actual per-component cost table (the estimates elsewhere in this plan
are estimates):

| checkpoint | date | spend should be under |
|---|---|---|
| first week of real use | 2026-10-14 | ~$23 |
| one third of the window | 2026-11-06 | ~$100 |
| two thirds of the window | 2026-12-06 | ~$200 |

The first checkpoint has one named question to answer before anything else: **is a
GKE cluster-management fee being charged?** ADR 0001 expects it to be waived by the
free tier (one cluster's fee per billing account) and does not assume it. This is
the largest single unknown in the budget at ~$2.40/day, so the first table should
show a GKE row either at $0 with the waiver visible as a credit line, or at the
list rate — and if it is the latter, ADR 0001 is revisited before more is built on
GKE.

Record the **turn-off order** here: what gets switched off first when spend runs
ahead — frontend/sandbox scale-to-zero already handles the rest.

**Done when:** each checkpoint has a dated note in this repo, and either the line
is under the straight-line figure or the plan is amended with the number that
broke it.

**Status: the measurement path exists now (`make cost-report`); the first reading
is blocked on one console switch, and one bug in the alarm was found on the way.**

- **There was no billing export, so there were no numbers to read.** The project
  has no BigQuery datasets at all — the usage export had never been enabled — and
  the budget API exposes only the *configuration* of a budget, not its running
  figure. `billing/budget.utilization` is not queryable from this project's
  Monitoring scope either (the metric descriptor does not exist there). So M10
  began by building the instrument: **`scripts/cost-report.py`** (`make
cost-report`) queries the export, breaks it down by service and SKU, and reports
  **cost and credits separately**, because the trial credit makes the invoice small
  rather than the platform cheap — and the daily rate it prints is computed from
  cost, not net. If the export is missing it exits 2 with the console steps.
- **The thing to do once, by hand: enable the export.** Billing → Budgets & costs →
  Billing export → *BigQuery usage export* → this project. It creates
  `gcp_billing_export_v1_01C0D4-4C9481-8E0DC4` and **is not backfilled**, so the
  day it is switched on is the first day the platform is measurable. AGENTS.md now
  lists it alongside DNS as something Terraform deliberately does not create.
- **A real bug: the tripwire was measuring the wrong number.** `credit_types_treatment` "specifies how credits should be treated when determining spend for
  threshold calculations", and the platform budget had `INCLUDE_ALL_CREDITS` — so
  the $70 alarm would have subtracted the trial credit out of the figure it was
  watching, and could not have fired during the exact period it exists to watch.
  The platform budget is now `EXCLUDE_ALL_CREDITS`: it measures what the platform
  *costs*. The canary deliberately keeps `INCLUDE_ALL_CREDITS`: that one asks the
  wallet's question, *am I actually paying*. Applied in-place, both budgets
  otherwise unchanged.
- **Not a bug, checked rather than assumed:** the budgets have no
  `notifications_rule`, and the API returns an empty one. That is not a silent
  alarm — threshold alerts go to the default recipients (Billing Account
  Administrator/User on this account) unless `disable_default_iam_recipients` is
  set. The Terraform comment saying so was right; it now says *why* it is right,
  because "no notification rule in the file" reads like a missing feature.
- **Why the first checkpoint is a week away and not today:** the cluster is
  ~15 hours old and the export lags by hours to a day. A reading taken now is one
  day of running reported as a period, which is exactly the arithmetic this
  milestone exists to refuse. The 2026-10-14 row stands.

**Turn-off order** (what gets switched off first if spend runs ahead — recorded
here rather than decided during an alarm, per CONTEXT.md): the order is chosen by
what the product can still do without it, and every step is reversible by editing
one overlay.

1. **Sandbox to zero replicas.** The last thing a reader touches is content; with no
   sandbox, an existing session cannot render new slides, but sign-in, sessions in
   progress, and review cards still work. Nothing else is asked to change.
2. **Frontend to zero.** Reading is gone; the API and any embedded host still work.
   (With no frontend there is no browser entry point, so this is the point where the
   product is dark to a person — which is why it comes second, not first.)
3. **Backend to zero.** Only now, because stopping it stops auth, sessions and the
   internal calls the sandbox and frontend depend on.
4. **Never the database, and never the nightly dump.** Turning off the server while
   keeping the volume costs most of the floor and loses the point; deleting the
   volume is not a turn-off, it is a decision to lose data, and it is not reversible
   from an overlay. The backup CronJob is the cheapest thing running and the last
   thing that should stop.

The first two are the ones already wired: `replica-floor.yaml` is where the floor
lives, and dropping a tier to zero is an edit there, not a `kubectl scale` — hand-run
replicas are drift and the next deploy removes them (AGENTS.md, "Deploys").
