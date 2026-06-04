

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

  redis_clusters = { for c in local.env.redis.clusters : c.name => c }

  tls_enabled = length(oci_load_balancer_certificate.this) > 0

  private_subnet_cidrs = [for i in range(local.env.vcn.availability_domains_qty) : cidrsubnet(local.env.vcn.cidr_block, 4, i + 8)]

  nfs_mount_ips = { for i in range(local.env.vcn.availability_domains_qty) : tostring(i) => data.oci_core_private_ip.nfs_mount_target[i].ip_address }

  pool_lb_configs = {
    varnish = [
      { lb_id = oci_load_balancer_load_balancer.this.id, backend_set_name = oci_load_balancer_backend_set.varnish.name, port = 80 }
    ]
    frontend = [
      { lb_id = oci_load_balancer_load_balancer.this.id, backend_set_name = oci_load_balancer_backend_set.frontend.name, port = 8080 },
      { lb_id = oci_load_balancer_load_balancer.internal.id, backend_set_name = oci_load_balancer_backend_set.internal_frontend.name, port = 8080 },
    ]
  }
}
