
///////////////////////////////////////////////////////////[ BASTION SERVICE ]/////////////////////////////////////////////////////

resource "oci_bastion_bastion" "this" {
  compartment_id               = local.env.oci.compartment_ocid
  bastion_type                 = "STANDARD"
  target_subnet_id             = oci_core_subnet.private[0].id
  name                         = "${local.project}-bastion"
  client_cidr_block_allow_list = var.bastion_allowed_cidrs
  freeform_tags                = local.default_tags
}
