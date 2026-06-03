

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
  message_format        = "ONS_OPTIMIZED"
  pending_duration      = "PT5M"
}

resource "oci_monitoring_alarm" "memory_high" {
  compartment_id        = local.env.oci.compartment_ocid
  display_name          = "${local.project}-memory-high"
  destinations          = [oci_ons_notification_topic.default.id]
  is_enabled            = true
  metric_compartment_id = local.env.oci.compartment_ocid
  namespace             = "oci_computeagent"
  query                 = "MemoryUtilization[5m].mean() > 90"
  severity              = "WARNING"
  freeform_tags         = local.default_tags
  message_format        = "ONS_OPTIMIZED"
  pending_duration      = "PT5M"
}

resource "oci_monitoring_alarm" "lb_5xx" {
  compartment_id        = local.env.oci.compartment_ocid
  display_name          = "${local.project}-lb-5xx"
  destinations          = [oci_ons_notification_topic.default.id]
  is_enabled            = true
  metric_compartment_id = local.env.oci.compartment_ocid
  namespace             = "oci_lbaas"
  query                 = "Http5xxResponses[5m].sum() > 50"
  severity              = "CRITICAL"
  freeform_tags         = local.default_tags
  message_format        = "ONS_OPTIMIZED"
  pending_duration      = "PT2M"
}

resource "oci_monitoring_alarm" "lb_unhealthy_backends" {
  compartment_id        = local.env.oci.compartment_ocid
  display_name          = "${local.project}-lb-unhealthy-backends"
  destinations          = [oci_ons_notification_topic.default.id]
  is_enabled            = true
  metric_compartment_id = local.env.oci.compartment_ocid
  namespace             = "oci_lbaas"
  query                 = "UnHealthyBackendServers[5m].max() > 0"
  severity              = "CRITICAL"
  freeform_tags         = local.default_tags
  message_format        = "ONS_OPTIMIZED"
  pending_duration      = "PT2M"
}
