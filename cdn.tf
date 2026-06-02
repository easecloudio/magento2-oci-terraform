
///////////////////////////////////////////////////////////[ CDN ]/////////////////////////////////////////////////////

# OCI CDN (Oracle CDN powered by Akamai) is configured separately in the OCI console
# or via CLI. Point the CDN origin to the Load Balancer IP output below.
#
# For self-hosted Varnish acting as CDN layer, no additional resource is needed —
# Varnish handles caching at the load balancer tier.
#
# Reference: https://docs.oracle.com/en-us/iaas/Content/CDN/home.htm

locals {
  cdn_note = "OCI CDN origin: ${oci_load_balancer_load_balancer.this.ip_addresses[0].ip_address}"
}
