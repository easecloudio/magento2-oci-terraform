

///////////////////////////////////////////////////////////[ SERVICE DISCOVERY - PRIVATE DNS ]/////////////////////////////////////////////////////

resource "oci_dns_view" "internal" {
  compartment_id = local.env.oci.compartment_ocid
  display_name   = "${local.project}-internal-view"
  scope          = "PRIVATE"
  freeform_tags  = local.default_tags
}

resource "oci_dns_zone" "internal" {
  compartment_id = local.env.oci.compartment_ocid
  name           = "${local.env.brand}.internal"
  zone_type      = "PRIMARY"
  scope          = "PRIVATE"
  view_id        = oci_dns_view.internal.id
  freeform_tags  = local.default_tags
}

resource "oci_dns_rrset" "mysql" {
  zone_name_or_id = oci_dns_zone.internal.id
  domain          = "mysql.${local.env.brand}.internal"
  rtype           = "CNAME"
  view_id         = oci_dns_view.internal.id
  scope           = "PRIVATE"

  items {
    domain = "mysql.${local.env.brand}.internal"
    rtype  = "CNAME"
    ttl    = 60
    rdata  = "${oci_mysql_mysql_db_system.this.endpoints[0].hostname}."
  }
}

resource "oci_dns_rrset" "redis" {
  for_each        = oci_redis_redis_cluster.this
  zone_name_or_id = oci_dns_zone.internal.id
  domain          = "redis-${each.key}.${local.env.brand}.internal"
  rtype           = "A"
  view_id         = oci_dns_view.internal.id
  scope           = "PRIVATE"

  items {
    domain = "redis-${each.key}.${local.env.brand}.internal"
    rtype  = "A"
    ttl    = 60
    rdata  = each.value.primary_endpoint_ip_address
  }
}

resource "oci_dns_rrset" "opensearch" {
  zone_name_or_id = oci_dns_zone.internal.id
  domain          = "opensearch.${local.env.brand}.internal"
  rtype           = "CNAME"
  view_id         = oci_dns_view.internal.id
  scope           = "PRIVATE"

  items {
    domain = "opensearch.${local.env.brand}.internal"
    rtype  = "CNAME"
    ttl    = 60
    rdata  = "${oci_opensearch_opensearch_cluster.this.opensearch_fqdn}."
  }
}
