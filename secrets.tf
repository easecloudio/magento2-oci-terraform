

///////////////////////////////////////////////////////////[ OCI VAULT + SECRETS ]/////////////////////////////////////////////////////

resource "oci_kms_vault" "this" {
  compartment_id = local.env.oci.compartment_ocid
  display_name   = "${local.project}-vault"
  vault_type     = "DEFAULT"
  freeform_tags  = local.default_tags
}

resource "oci_kms_key" "this" {
  compartment_id      = local.env.oci.compartment_ocid
  display_name        = "${local.project}-master-key"
  management_endpoint = oci_kms_vault.this.management_endpoint
  freeform_tags       = local.default_tags

  key_shape {
    algorithm = "AES"
    length    = 32
  }
}

locals {
  secrets = {
    MARIADB_PASSWORD    = random_password.this["database"].result
    REDIS_PASSWORD      = random_password.this["redis"].result
    OPENSEARCH_PASSWORD = random_password.this["opensearch"].result
    OPENSEARCH_ADMIN    = random_string.this["opensearch_admin"].result
    ADMIN_PATH          = random_string.this["admin_path"].result
    HEALTH_CHECK        = random_string.this["health_check"].result
    SECURITY_HEADER     = random_uuid.this.result
  }
}

resource "oci_vault_secret" "this" {
  for_each       = local.secrets
  compartment_id = local.env.oci.compartment_ocid
  vault_id       = oci_kms_vault.this.id
  key_id         = oci_kms_key.this.id
  secret_name    = "${local.project}-${lower(replace(each.key, "_", "-"))}"
  freeform_tags  = local.default_tags

  secret_content {
    content_type = "BASE64"
    content      = base64encode(each.value)
  }
}
