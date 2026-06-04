
///////////////////////////////////////////////////////////[ INPUT VARIABLES ]/////////////////////////////////////////////////////

variable "ssh_public_key" {
  description = "SSH public key to inject into compute instances. Leave empty to skip."
  type        = string
  default     = ""
}

variable "bastion_allowed_cidrs" {
  description = "Client CIDR blocks allowed to create Bastion sessions. Must be non-empty to restrict access."
  type        = list(string)
  default     = []
}
