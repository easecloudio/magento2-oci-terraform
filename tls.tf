
///////////////////////////////////////////////////////////[ TLS CERTIFICATE ]/////////////////////////////////////////////////////

# Supply actual PEM content via TF_VAR_ssl_certificate_pem and TF_VAR_ssl_private_key_pem
# environment variables, or from a secrets manager in CI.
variable "ssl_certificate_pem" {
  description = "PEM-encoded certificate chain for the domain"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ssl_private_key_pem" {
  description = "PEM-encoded private key for the domain"
  type        = string
  sensitive   = true
  default     = ""
}

resource "oci_load_balancer_certificate" "this" {
  count = var.ssl_certificate_pem != "" ? 1 : 0

  load_balancer_id   = oci_load_balancer_load_balancer.this.id
  certificate_name   = "${local.project}-cert"
  public_certificate = var.ssl_certificate_pem
  private_key        = var.ssl_private_key_pem
}
