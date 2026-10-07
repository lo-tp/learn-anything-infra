# bootstrap — the one root that cannot live in the state it manages

This root creates a single resource: the versioned GCS bucket that holds Terraform
state for every other root. A backend cannot create itself, so this root keeps its
own state here, on disk. That is the whole cost of the design, and it is
deliberate: if `bootstrap.tfstate` is ever lost, the fix is `terraform apply`
again against an empty bucket, not importing a cluster.

    cd bootstrap && make -C .. tf-init tf-apply ROOT=bootstrap

Run it once, before `gcp/`. After that it should sit unchanged; touching it is
how you end up with two state buckets.
