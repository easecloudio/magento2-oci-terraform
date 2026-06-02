
////////////////////////////////////////////////////////[ VCN NETWORKING ]////////////////////////////////////////////////

resource "oci_core_vcn" "this" {
  compartment_id = local.env.oci.compartment_ocid
  cidr_block     = local.env.vcn.cidr_block
  display_name   = "${local.project}-vcn"
  dns_label      = local.env.vcn.dns_label
  freeform_tags  = local.default_tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-igw"
  enabled        = true
  freeform_tags  = local.default_tags
}

resource "oci_core_default_route_table" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_route_table_id

  route_rules {
    network_entity_id = oci_core_internet_gateway.this.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }

  freeform_tags = local.default_tags
}

resource "oci_core_subnet" "public" {
  count = local.env.vcn.availability_domains_qty

  compartment_id      = local.env.oci.compartment_ocid
  vcn_id              = oci_core_vcn.this.id
  cidr_block          = cidrsubnet(local.env.vcn.cidr_block, 4, count.index)
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[count.index].name
  display_name        = "${local.project}-subnet-${count.index}"
  dns_label           = "subnet${count.index}"
  security_list_ids   = [oci_core_vcn.this.default_security_list_id]
  route_table_id      = oci_core_vcn.this.default_route_table_id
  freeform_tags       = local.default_tags
}

resource "oci_core_dhcp_options" "this" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-dhcp"
  freeform_tags  = local.default_tags

  options {
    type        = "DomainNameServer"
    server_type = "VcnLocalPlusInternet"
  }
  options {
    type                = "SearchDomain"
    search_domain_names = ["${local.env.vcn.dns_label}.oraclevcn.com"]
  }
}
