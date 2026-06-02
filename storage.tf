
///////////////////////////////////////////////////////////[ OBJECT STORAGE ]/////////////////////////////////////////////////////

resource "oci_objectstorage_bucket" "this" {
  for_each       = toset(local.env.object_storage.buckets)
  compartment_id = local.env.oci.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "${local.project}-${each.key}"
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
  freeform_tags  = local.default_tags
}
