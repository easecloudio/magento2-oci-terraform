

///////////////////////////////////////////////////////////[ PUBLIC DNS ]/////////////////////////////////////////////////////

resource "oci_dns_zone" "public" {
  compartment_id = local.env.oci.compartment_ocid
  name           = local.env.domain
  zone_type      = "PRIMARY"
  scope          = "GLOBAL"
  freeform_tags  = local.default_tags
}
