

///////////////////////////////////////////////////////////[ MYSQL DATABASE ]/////////////////////////////////////////////////////

resource "oci_mysql_mysql_db_system" "this" {
  compartment_id          = local.env.oci.compartment_ocid
  display_name            = "${local.project}-mysql"
  shape_name              = local.env.mysql.shape
  admin_username          = local.env.mysql.admin_username
  admin_password          = random_password.this["database"].result
  data_storage_size_in_gb = local.env.mysql.storage_size_gb
  subnet_id               = oci_core_subnet.public[0].id
  availability_domain     = data.oci_identity_availability_domains.this.availability_domains[0].name
  mysql_version           = local.env.mysql.engine_version
  hostname_label          = "${local.project}-mysql"
  nsg_ids                 = [oci_core_network_security_group.database.id]

  backup_policy {
    is_enabled        = true
    retention_in_days = local.env.mysql.backup_retention_days
    window_start_time = "01:00"
  }

  freeform_tags = local.default_tags
}
