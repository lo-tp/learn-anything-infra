# ── The public surface: one address, the hostnames that point at it ──────────
#
# A global (not regional) address, because this is a global Application Load
# Balancer: the forwarding rule, the target proxy and the health checks are global
# resources regardless of where the cluster is. The address is **reserved by name**
# rather than discovered after the fact, and the reason is the sequence in
# docs/adr/0004-dns-stays-at-namecheap.md: the records are typed by hand into
# Namecheap, so the value they carry has to be knowable before they are typed, and
# it has to survive every later apply. A load balancer that picked its own address
# would make those rows — and the certificate that follows them — wrong the first
# time the cluster was rebuilt.
resource "google_compute_global_address" "ingress_ip" {
  name         = "learn-anything-ingress-ip"
  description  = "The one address every public surface of Learn Anything resolves to. Referenced by name from the Ingress annotation; typed by hand into the registrar."
  address_type = "EXTERNAL"

  depends_on = [google_project_service.required]
}

# What the DNS set is, as data rather than as a memory of what was typed into a
# dashboard. This is the source of truth the ADR accepts: the records themselves
# are not created here, but *which* records belong there is.
#
# The staging hosts are declared alongside the production ones on purpose. They
# cost nothing until something resolves to them, and the alternative — inventing
# them at staging time — is how a staging surface ends up with a name that no
# certificate covers and no record points at.
locals {
  dns_zone = var.dns_zone

  # Every host this project owns on that zone, in the order they should appear in
  # the dashboard: production first, then staging. The sandbox host is public for
  # one reason — the `/slides/{id}` iframe is fetched by the browser — which
  # CONTEXT.md records under *public surface*; its /api/compile stays internal.
  a_record_hosts = concat(
    [for h in var.public_hostnames : "${h}.${var.dns_zone}"],
    [for h in var.staging_hostnames : "${h}.${var.dns_zone}"],
  )

  # …and which of them are expected to resolve *today*. The staging hosts are
  # declared but not pointed: an address has exactly one global forwarding rule, so
  # a second environment is a second address and a second (billed) forwarding rule,
  # not another set of host rules on the first one — see docs/plan/m06-one-public-surface-three-hostnames-real-certificates.md and
  # manifests/overlays/prod/ingress.yaml. A record that resolves to an address with
  # no rule behind it looks exactly like a broken deploy, so those rows are printed
  # separately and marked as held rather than typed and forgotten.
  live_hosts     = [for h in var.public_hostnames : "${h}.${var.dns_zone}"]
  deferred_hosts = [for h in var.staging_hostnames : "${h}.${var.dns_zone}"]
}
