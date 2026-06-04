

///////////////////////////////////////////////////////////[ DATA SOURCES ]/////////////////////////////////////////////////////

data "oci_identity_availability_domains" "this" {
  compartment_id = local.env.oci.tenancy_ocid
}

data "oci_core_images" "this" {
  compartment_id           = local.env.oci.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  filter {
    name   = "display_name"
    values = [".*aarch64.*"]
    regex  = true
  }
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = local.env.oci.compartment_ocid
}

# Resolve the NFS mount target OCID to an actual private IP address.
# oci_file_storage_mount_target.private_ip_ids returns a list of private IP OCIDs.
data "oci_core_private_ip" "nfs_mount_target" {
  private_ip_id = oci_file_storage_mount_target.this.private_ip_ids[0]
}
