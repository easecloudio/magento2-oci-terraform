

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
