
///////////////////////////////////////////////////////////[ IDENTITY ]/////////////////////////////////////////////////////

resource "oci_identity_dynamic_group" "compute" {
  compartment_id = local.env.oci.tenancy_ocid
  name           = "${local.project}-compute-dg"
  description    = "Dynamic group for ${local.project} compute instances"
  matching_rule  = "Any {all {instance.compartment.id = '${local.env.oci.compartment_ocid}', tag.oracle-tags.CreatedBy.value = 'terraform'}}"
}

resource "oci_identity_policy" "compute" {
  compartment_id = local.env.oci.compartment_ocid
  name           = "${local.project}-compute-policy"
  description    = "Allows compute instances to access vault, object storage, and file storage"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to read secret-bundles in compartment id ${local.env.oci.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to use vaults in compartment id ${local.env.oci.compartment_ocid}",
    # media-optimized and system: read-only; media and backup have manage grants below
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to read objects in compartment id ${local.env.oci.compartment_ocid} where any {target.bucket.name = '${local.project}-media-optimized', target.bucket.name = '${local.project}-system'}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to manage objects in compartment id ${local.env.oci.compartment_ocid} where target.bucket.name = '${local.project}-backup'",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to manage objects in compartment id ${local.env.oci.compartment_ocid} where target.bucket.name = '${local.project}-media'",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to use file-family in compartment id ${local.env.oci.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to read instance-family in compartment id ${local.env.oci.compartment_ocid}",
  ]
}
