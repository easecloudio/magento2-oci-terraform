

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
