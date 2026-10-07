# The backend runs as a single replica

The backend keeps its graph checkpoints in the process — one in-memory checkpoint
store shared by every graph, alive for the process lifetime and gone on restart,
with the domain database providing step-granularity recovery. So more than one
replica would split that state across processes and break mid-session resume
unless requests were pinned to a replica. We run **exactly one replica** with a
`Recreate` rollout strategy, and we do not scale it to zero.

## Considered options

- **Two or more replicas with session affinity** — better availability, but the
  correctness of resume then depends on routing, and the in-process store is still
  the real limit.
- **Share the checkpoint store** (a database-backed checkpointer) — the honest
  fix, and a change to the backend's code, not to its deployment. Deferred.
- **Scale the backend to zero too** — cheapest. Rejected: its cold start would
  stack on top of multi-minute LLM graphs, and a paused process throws the
  checkpoint store away anyway.

## Consequences

- A restart costs one in-flight session its checkpoint. Accepted: recovery is
  already designed around it, at step granularity, from the database.
- Deploys use `Recreate`, so there is a brief window where nothing serves the
  API. A rolling update would mean two processes holding separate state.
- **Availability is one pod deep.** If that stops being acceptable, the fix is
  the shared checkpoint store in the backend, not a bigger replica count here.
