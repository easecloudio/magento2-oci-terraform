

///////////////////////////////////////////////////////////[ OPENSEARCH ]/////////////////////////////////////////////////////

resource "oci_opensearch_opensearch_cluster" "this" {
  compartment_id                     = local.env.oci.compartment_ocid
  display_name                       = "${local.project}-opensearch"
  software_version                   = local.env.opensearch.software_version
  data_node_count                    = local.env.opensearch.node_count
  data_node_host_type                = "FLEX"
  data_node_host_ocpu_count          = 1
  data_node_host_memory_gb           = 16
  data_node_storage_gb               = 50
  master_node_count                  = local.env.opensearch.master_node_count
  master_node_host_type              = "FLEX"
  master_node_host_ocpu_count        = 1
  master_node_host_memory_gb         = 8
  opendashboard_node_count           = local.env.opensearch.opendashboard_node_count
  opendashboard_node_host_ocpu_count = 1
  opendashboard_node_host_memory_gb  = 8
  subnet_compartment_id              = local.env.oci.compartment_ocid
  vcn_compartment_id                 = local.env.oci.compartment_ocid
  vcn_id                             = oci_core_vcn.this.id
  subnet_id                          = oci_core_subnet.private[0].id
  nsg_id                             = oci_core_network_security_group.opensearch.id
  freeform_tags                      = local.default_tags
}
