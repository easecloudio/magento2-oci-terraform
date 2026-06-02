

///////////////////////////////////////////////////////////[ OCI BUDGET ]/////////////////////////////////////////////////////

resource "oci_budget_budget" "this" {
  compartment_id = local.env.oci.tenancy_ocid
  description    = "Budget alert for ${local.project}"
  amount         = local.env.budget.amount
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [local.env.oci.compartment_ocid]
  display_name   = "${local.project}-budget"
  freeform_tags  = local.default_tags
}

resource "oci_budget_alert_rule" "this" {
  budget_id      = oci_budget_budget.this.id
  type           = "ACTUAL"
  threshold      = local.env.budget.threshold_percent
  threshold_type = "PERCENTAGE"
  display_name   = "${local.project}-budget-alert"
  recipients     = local.env.admin_email
  message        = "Budget alert: ${local.project} has exceeded ${local.env.budget.threshold_percent}% of monthly budget"
  freeform_tags  = local.default_tags
}
