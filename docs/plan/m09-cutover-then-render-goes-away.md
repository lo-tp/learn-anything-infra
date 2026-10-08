# M9 — Cutover, then Render goes away

← [plan index](./index.md) · [M8](./m08-prove-it-then-let-it-use-the-real-llm.md) · next [M10](./m10-verify-the-budget-claim-with-numbers.md)

Decide first whether the Render Postgres data carries over: if it does, `pg_dump`
it and restore into the in-cluster database before the flip. Then repoint, watch,
and only then stop the Render services and delete `render.yaml` and the "Deploy
(Render)" section of the backend README
([CONTEXT.md → cutover](../../CONTEXT.md)).

**Done when:** `learn.lotp.xyz` serves a real session, no Render service is
serving traffic, and `render.yaml` no longer exists in the backend repo. The
cutover is also the first time a `pg_dump` archive is read back: do the restore
into the in-cluster database with `pg_restore`, not by hand, so the nightly backup
has been exercised by the time it is the only recovery path (M4 wrote archives;
nothing has restored one yet).

**Status: one clause done, one decided, two waiting on a hand at a dashboard and
the M8 key.**

- **No *Render* data carries over (decided 2026-10-08).** The Render Postgres is
  left where it is. That is a decision, not an oversight: what is on Render is
  development history — sessions made while building the app — and carrying it in
  would mean shipping user-visible rows whose LLM answers came from a different
  model at a different quality, into a product about to be judged on its output. The
  in-cluster database is the only database the product has.
- **Development data from the laptop did carry over, the same day, on request.**
  The source was the local development database (`learn-anything-backend-db-1`, the
  Compose Postgres of the backend repo), **not** Render's — and it is the same kind
  of history the paragraph above argues against, so the contradiction is stated
  rather than hidden: 23 users, 53 sessions, 36 plans, 862 slide contents, 244 probe
  questions, 169 step materials, 152 failed slides, 1,838 stage timings — several of
  them produced by prompts and models that no longer exist. What makes it tolerable
  is that the copy is a *replace*, so the cluster holds exactly one set of rows, and
  that it is reversible, so it is not a commitment.
  - **The gate was the migration revision, not the schema text.** Both databases
    reported `alembic_version = c3d4e5f6a7b8` and the same 11 tables. Had they
    differed, a data copy would have been a schema edit made in `psql` — the thing
    M5 refuses: the migrations are the source of truth, and they run through the Job.
  - **Replace, not append.** Every id here is an integer `nextval`, and the target
    already held rows in the same id range (the six users and one session from the
    M6/M8 acceptance runs), so an append would have collided on primary keys. The
    dump was `pg_dump --clean --if-exists --no-owner --no-privileges`; the load was
    **one transaction** (`psql -1 -v ON_ERROR_STOP=1`) run inside the database pod,
    so the app saw either the old data or the new data and never a half-state; the 8
    foreign keys stayed enforced, which is why orphan rows are not possible; and the
    sequences came along (`users_id_seq` at 23, above a maximum id of 23), so a later
    insert cannot collide with a copied one.
  - **Verified as data, then as a running application.** Row counts in the cluster
    match the source table by table. Then `register → login → GET /auth/me` through
    `api.lotp.xyz` returned 201, 200 and 200 with the correct user id — on the
    *existing* connection pool, which is the point: PostgreSQL drops prepared
    statements when the objects they reference are dropped, so a pool open across a
    `DROP`/`CREATE` is exactly where a break would surface. It did not. The probe
    user was deleted afterwards and the counts re-compared, so what remains is the
    source's data and nothing added by the check.
  - **The recovery point moved.** `learn_anything-2026-10-07T17:30:05Z.sql.gz` — the
    archive the drill below read back — is from *before* this import, so restoring it
    today would undo the copy. The next nightly dump is the first archive that
    contains this state; until it exists, that is the only fact about recoverability
    worth stating.
- **`render.yaml` is gone** (backend `d90b13e`), and with it the "Deploy (Render)"
  section of that README, `scripts/build.sh` — whose only user was the blueprint's
  `buildCommand`, its three steps now living in the Dockerfile, the CI workflow and
  the migration Job — and the comments that compared the Dockerfile to a build that
  no longer happens. This repository is the only place that says where the product
  runs.
- **"No Render service is serving traffic" needs a click in a dashboard**, not a
  command in this repo: Blueprint → each service → **Stop Service**, then the free
  Postgres instance. Until that happens two deployments share nothing but a name:
  different `JWT_SECRET`, different database, different users. That is not a
  correctness problem, and it is the reason "which one am I using?" should be
  answered in favour of the surfaces, not left ambiguous.
- **"Serves a real session" is M8's, in the literal sense**: it cannot be observed
  until `openai-api-key` / `openai-base-url` / `llm-model` hold a real endpoint.
  The surface, the auth and the sandbox fetch are already proven green through the
  public host (`make acceptance`, M6); the model is the only unresolved hop.
- **The restore drill ran (2026-10-08, ~02:00 local), and it is now a command:
  `make restore-drill`.** The newest nightly archive —
  `learn_anything-2026-10-07T17:30:05Z.sql.gz` — was copied into a throwaway
  postgres pod in the same namespace (no network from the pod: these pods have no
  egress, and a drill that needed it would be a second thing to debug) and
  `pg_restore`d into a scratch database in 3 seconds. It produced the same 11
  tables the live database has, with matching row counts everywhere except
  `sessions` (live 1, archive 0) and `users` (live 6, archive 3) — which is the
  expected shape of the truth: the archive is a snapshot from 17:30Z, and the
  M6/M8 acceptance runs happened after it. The script prints that reasoning next to
  the numbers, because "differs" is otherwise easy to misread as corruption.
  Teardown is the exit trap, so a skipped cleanup cannot happen by forgetting.
- One lesson the drill paid for: `kubectl exec` lands in the postgres image as
  **root**, so `pg_restore`/`psql` without `-U postgres` fail with `role "root"
  does not exist` — on the scratch pod only; the live database's app role is
  `learn`. Two different superusers in one command, which is worth writing down
  somewhere.
