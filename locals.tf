

///////////////////////////////////////////////////////////[ LOCALS ]/////////////////////////////////////////////////////

locals {
  environment = lower(terraform.workspace)

  config_files = {
    developer  = try(file("${abspath(path.root)}/developer.config.yaml"), "")
    staging    = try(file("${abspath(path.root)}/staging.config.yaml"), "")
    production = try(file("${abspath(path.root)}/production.config.yaml"), "")
  }

  env     = yamldecode(local.config_files[local.environment])
  project = lower("${local.env.brand}-${local.env.codename}")

  default_tags = {
    terraform   = "true"
    brand       = local.env.brand
    environment = local.environment
    project     = local.project
  }

  db_name = replace(local.project, "-", "_")

  mysql_params = { for p in local.env.mysql.parameters : p.name => p.value }

  tls_enabled = length(oci_load_balancer_certificate.this) > 0

  private_subnet_cidrs = [for i in range(local.env.vcn.availability_domains_qty) : cidrsubnet(local.env.vcn.cidr_block, 4, i + 8)]

  pool_lb_config = {
    varnish  = { backend_set_name = oci_load_balancer_backend_set.varnish.name, port = 80 }
    frontend = { backend_set_name = oci_load_balancer_backend_set.frontend.name, port = 8080 }
  }
}
