

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
}
