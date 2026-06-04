

///////////////////////////////////////////////////////////[ PUBLIC DNS ]/////////////////////////////////////////////////////

resource "oci_dns_zone" "public" {
  compartment_id = local.env.oci.compartment_ocid
  name           = local.env.domain
  zone_type      = "PRIMARY"
  scope          = "GLOBAL"
  freeform_tags  = local.default_tags
}

resource "oci_dns_rrset" "apex" {
  zone_name_or_id = oci_dns_zone.public.id
  domain          = local.env.domain
  rtype           = "A"
  scope           = "GLOBAL"

  items {
    domain = local.env.domain
    rtype  = "A"
    ttl    = 300
    rdata  = oci_load_balancer_load_balancer.this.ip_address_details[0].ip_address
  }
}

# Only created when TLS is enabled — admin subdomain routing only works on the HTTPS listener
resource "oci_dns_rrset" "admin" {
  count           = local.tls_enabled ? 1 : 0
  zone_name_or_id = oci_dns_zone.public.id
  domain          = local.admin_domain
  rtype           = "A"
  scope           = "GLOBAL"

  items {
    domain = local.admin_domain
    rtype  = "A"
    ttl    = 300
    rdata  = oci_load_balancer_load_balancer.this.ip_address_details[0].ip_address
  }
}

resource "oci_dns_rrset" "www" {
  zone_name_or_id = oci_dns_zone.public.id
  domain          = "www.${local.env.domain}"
  rtype           = "CNAME"
  scope           = "GLOBAL"

  items {
    domain = "www.${local.env.domain}"
    rtype  = "CNAME"
    ttl    = 300
    rdata  = "${local.env.domain}."
  }
}
