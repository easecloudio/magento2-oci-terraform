
///////////////////////////////////////////////////////////[ FILE STORAGE (NFS) ]/////////////////////////////////////////////////////

resource "oci_file_storage_file_system" "this" {
  # Single file system — it is regional; mount targets are per-AD
  compartment_id      = local.env.oci.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[0].name
  display_name        = "${local.project}-fss"
  freeform_tags       = local.default_tags
}

resource "oci_file_storage_mount_target" "this" {
  count               = local.env.vcn.availability_domains_qty
  compartment_id      = local.env.oci.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[count.index].name
  subnet_id           = oci_core_subnet.private[count.index].id
  display_name        = "${local.project}-mount-target-${count.index}"
  nsg_ids             = [oci_core_network_security_group.nfs.id]
  freeform_tags       = local.default_tags
}

resource "oci_file_storage_export_set" "this" {
  count           = local.env.vcn.availability_domains_qty
  mount_target_id = oci_file_storage_mount_target.this[count.index].id
  display_name    = "${local.project}-export-set-${count.index}"
}

resource "oci_file_storage_export" "this" {
  for_each = {
    for pair in flatten([
      for mt_idx in range(local.env.vcn.availability_domains_qty) : [
        for mount_key, mount_val in local.env.file_storage.mounts : {
          key       = "${mt_idx}-${mount_key}"
          mt_idx    = mt_idx
          mount_key = mount_key
          mount_val = mount_val
        }
      ]
    ]) : pair.key => pair
  }

  export_set_id  = oci_file_storage_export_set.this[each.value.mt_idx].export_set_id
  file_system_id = oci_file_storage_file_system.this.id
  path           = "/${each.value.mount_key}"

  # Scoped to this AD's private subnet only. The NFS NSG still allows the full compute NSG
  # across all ADs — that asymmetry is intentional defense-in-depth (NSG = network layer,
  # export_options = NFS protocol layer).
  dynamic "export_options" {
    for_each = toset([cidrsubnet(local.env.vcn.cidr_block, 4, each.value.mt_idx + 8)])
    content {
      source                         = export_options.value
      access                         = "READ_WRITE"
      identity_squash                = "ROOT"
      require_privileged_source_port = false
    }
  }
}
