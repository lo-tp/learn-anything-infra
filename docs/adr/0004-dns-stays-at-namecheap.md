# DNS records stay at Namecheap, declared here and applied by hand

`lotp.xyz` is registered at Namecheap and its DNS stays there: the zone is not
imported into the cloud provider and the nameservers are never changed. Terraform
does not create the records, because Namecheap's API allowlists **individual IPs
rather than CIDR ranges**, offers no API to change that allowlist, and must be
enabled in the account by hand — so a CI pipeline with rotating runner IPs fails
mid-apply with `Invalid request IP`. Instead, the record set is declared in this
repo as a Terraform variable and printed by `terraform output dns_records`; a
human types those rows into the Namecheap dashboard.

## Considered options

- **Namecheap Terraform provider, CI-driven.** Rejected: the IP-allowlist
  limitation above is a Namecheap API limitation, not a provider bug, and it has
  no CIDR or self-service workaround. Its record model also rewrites the whole
  host list, which races across resources and throttles.
- **Provider, applied only from a laptop.** Rejected: it works until the local IP
  changes, and then the pipeline silently can't be re-run by anyone else.
- **Delegate only `learn.lotp.xyz` to the cloud provider's DNS.** Cleanest for
  Terraform and harmless to the blog, but it forces nested hostnames
  (`api.learn.lotp.xyz`), which was not wanted.
- **Move the whole zone.** Rejected: it puts a working blog one missed record from
  a dark week, for no gain beyond tidiness.

## Consequences

- **`terraform plan` cannot see drift in DNS.** This is the one place where the
  repo's "declared as code" rule stops short, so verifying a deploy includes
  comparing `terraform output dns_records` against the dashboard, not trusting
  state.
- Certificate issuance and the public surfaces are **gated on a manual step**: a
  missing record looks like a broken certificate, not a broken deploy.
- Nothing near `blog.lotp.xyz` is ever touched, so the foreign record stays
  foreign.
