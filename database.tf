

///////////////////////////////////////////////////////////[ MYSQL DATABASE ]/////////////////////////////////////////////////////

resource "oci_mysql_mysql_configuration" "this" {
  compartment_id = local.env.oci.compartment_ocid
  shape_name     = local.env.mysql.shape
  display_name   = "${local.project}-mysql-config"
  freeform_tags  = local.default_tags

  variables {
    max_allowed_packet       = tonumber(local.mysql_params["max_allowed_packet"])
    wait_timeout             = tonumber(local.mysql_params["wait_timeout"])
    interactive_timeout      = tonumber(local.mysql_params["interactive_timeout"])
    innodb_lock_wait_timeout = tonumber(local.mysql_params["innodb_lock_wait_timeout"])
  }
}

resource "oci_mysql_mysql_db_system" "this" {
  compartment_id          = local.env.oci.compartment_ocid
  display_name            = "${local.project}-mysql"
  shape_name              = local.env.mysql.shape
  admin_username          = local.env.mysql.admin_username
  admin_password          = random_password.this["database"].result
  data_storage_size_in_gb = local.env.mysql.storage_size_gb
  subnet_id               = oci_core_subnet.private[0].id
  availability_domain     = data.oci_identity_availability_domains.this.availability_domains[0].name
  mysql_version           = local.env.mysql.engine_version
  hostname_label          = "${local.project}-mysql"
  configuration_id        = oci_mysql_mysql_configuration.this.id
  is_highly_available     = local.environment == "production"

  backup_policy {
    is_enabled        = true
    retention_in_days = local.env.mysql.backup_retention_days
    window_start_time = "01:00"
  }

  freeform_tags = local.default_tags
}
