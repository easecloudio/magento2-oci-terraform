

///////////////////////////////////////////////////////////[ OCI EVENTS + NOTIFICATIONS ]/////////////////////////////////////////////////////

resource "oci_ons_notification_topic" "default" {
  compartment_id = local.env.oci.compartment_ocid
  name           = "${local.project}-notifications"
  description    = "Notifications for ${local.project} infrastructure events"
  freeform_tags  = local.default_tags
}

resource "oci_events_rule" "release_deploy" {
  compartment_id = local.env.oci.compartment_ocid
  display_name   = "${local.project}-release-deploy"
  description    = "Trigger on release zip upload to system Object Storage bucket"
  is_enabled     = true
  freeform_tags  = local.default_tags

  condition = jsonencode({
    eventType = ["com.oraclecloud.objectstorage.createobject"]
    data = {
      resourceName = ["${local.project}-system"]
      additionalDetails = {
        namespaceName = [data.oci_objectstorage_namespace.this.namespace]
      }
    }
  })

  actions {
    actions {
      action_type = "ONS"
      is_enabled  = true
      topic_id    = oci_ons_notification_topic.default.id
    }
  }
}
