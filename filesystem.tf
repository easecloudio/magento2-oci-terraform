
///////////////////////////////////////////////////////////[ FILE STORAGE (NFS) ]/////////////////////////////////////////////////////

resource "oci_file_storage_file_system" "this" {
  compartment_id      = local.env.oci.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[0].name
  display_name        = "${local.project}-fss"
  freeform_tags       = local.default_tags
}

resource "oci_file_storage_mount_target" "this" {
  compartment_id      = local.env.oci.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[0].name
  subnet_id           = oci_core_subnet.public[0].id
  display_name        = "${local.project}-mount-target"
  nsg_ids             = [oci_core_network_security_group.nfs.id]
  freeform_tags       = local.default_tags
}

resource "oci_file_storage_export_set" "this" {
  mount_target_id = oci_file_storage_mount_target.this.id
  display_name    = "${local.project}-export-set"
}

resource "oci_file_storage_export" "this" {
  for_each       = local.env.file_storage.mounts
  export_set_id  = oci_file_storage_mount_target.this.export_set_id
  file_system_id = oci_file_storage_file_system.this.id
  path           = "/${each.key}"

  export_options {
    source                         = local.env.vcn.cidr_block
    access                         = "READ_WRITE"
    identity_squash                = "NONE"
    require_privileged_source_port = false
  }
}
