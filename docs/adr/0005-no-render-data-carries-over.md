# No Render data carries over

The product was running on Render — a web service and a free PostgreSQL instance —
and cutover to this cluster could have imported that database. It does not: the
in-cluster database starts empty and is the only database the product has. The rows
on Render are development history, sessions made while building the app, and
carrying them in would mean shipping user-visible rows whose LLM answers came from
a different model at a different quality into a product about to be judged on its
output.

## Considered options

- **`pg_dump` from Render, restore into the StatefulSet.** Rejected on the argument
  above, not on difficulty: the schemas matched (same Alembic revision, 11 tables),
  so the copy would have been easy. A copy that is easy and wrong is still wrong.
- **Import and mark the old rows as legacy.** Rejected: it puts a second truth into
  a product whose whole surface is the quality of those rows, and nothing would
  read the marker.
- **Keep Render's Postgres as a read-only reference for a while.** Rejected: it
  keeps the billing account holding a second database, and the free instance is one
  of the things this cutover exists to stop paying for.

## Consequences

- **The first users are new users.** No history to migrate means nothing to verify
  after cutover except that the empty schema is the current migration — which the
  migration gate in M5 already proves.
- **One exception was made, the same day, and it is recorded rather than hidden.**
  Development data from the *laptop* (the backend repo's local Compose Postgres, not
  Render's) was copied in on request: 23 users, 53 sessions, 36 plans, 862 slide
  contents. That is exactly the kind of history this ADR argues against, so the
  contradiction is stated in [M9](../plan/m09-cutover-then-render-goes-away.md) with the method (a
  **replace**, not an append, so the cluster holds one set of rows) and the
  recovery point it moved (the 2026-10-07T17:30Z archive predates the import, so
  restoring it today would undo the copy). It is reversible, which is what made it
  acceptable as an experiment rather than a change of mind about Render.
- **Deleting the Render blueprint is part of this decision, not a separate
  cleanup.** With no data carried over and no second database, `render.yaml` in the
  backend repo would be a second place claiming to say where the product runs.
