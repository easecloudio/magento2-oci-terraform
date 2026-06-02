

///////////////////////////////////////////////////////////[ OCI MONITORING ALARMS ]/////////////////////////////////////////////////////

resource "oci_monitoring_alarm" "cpu_high" {
  compartment_id        = local.env.oci.compartment_ocid
  display_name          = "${local.project}-cpu-high"
  destinations          = [oci_ons_notification_topic.default.id]
  is_enabled            = true
  metric_compartment_id = local.env.oci.compartment_ocid
  namespace             = "oci_computeagent"
  query                 = "CpuUtilization[5m].mean() > 85"
  severity              = "WARNING"
  freeform_tags         = local.default_tags

  message_format   = "ONS_OPTIMIZED"
  pending_duration = "PT5M"
}
