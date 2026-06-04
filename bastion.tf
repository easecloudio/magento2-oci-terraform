

///////////////////////////////////////////////////////////[ BASTION SERVICE ]/////////////////////////////////////////////////////

variable "ssh_public_key" {
  description = "SSH public key to inject into compute instances. Leave empty to skip."
  type        = string
  default     = ""
}

variable "bastion_allowed_cidrs" {
  description = "Client CIDR blocks allowed to create Bastion sessions"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

resource "oci_bastion_bastion" "this" {
  compartment_id               = local.env.oci.compartment_ocid
  bastion_type                 = "STANDARD"
  target_subnet_id             = oci_core_subnet.public[0].id
  name                         = "${replace(local.project, "-", "")}bastion"
  client_cidr_block_allow_list = var.bastion_allowed_cidrs
  freeform_tags                = local.default_tags
}
