# PostgreSQL runs in the cluster, not Cloud SQL

The backend's only stateful dependency is PostgreSQL, and the whole platform has
~$3.33 a day to live on. Cloud SQL's smallest manageable instance is roughly
$1.5–2 a day on its own — half the budget for one component — so we run
PostgreSQL as a StatefulSet with a persistent disk inside the cluster, and buy
back the safety we gave up with a nightly `pg_dump` to object storage.

## Considered options

- **Cloud SQL, Enterprise, smallest class** — managed backups, SSL, patching.
  Rejected on cost: at this budget it out-earns the application itself.
- **Cloud SQL with `ON_DEMAND` activation** — sleeps between uses. Rejected: a
  cold database under a cold-starting app, for a component that should be the
  boring one.

## Consequences

- Durability is now ours. A failed node means waiting on a pod to reschedule, and
  a lost disk means restoring from the last dump — the restore path has to exist
  and be rehearsed, not merely available.
- "Infra owns the database" here means the workload, the volume and the dumps.
  The **schema** stays the backend's: migrations are its source of truth, and
  infra provides the server and the connection string.
- The data becomes easier to lose than a managed database would let it be, and
  that was accepted on purpose.
