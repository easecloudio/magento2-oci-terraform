
///////////////////////////////////////////////////////////[ INSTANCE CONFIGURATION ]/////////////////////////////////////////////////////

resource "oci_core_instance_configuration" "this" {
  for_each       = local.env.compute
  compartment_id = local.env.oci.compartment_ocid
  display_name   = "${local.project}-${each.key}-config"

  instance_details {
    instance_type = "compute"

    launch_details {
      compartment_id = local.env.oci.compartment_ocid
      shape          = each.value.shape

      shape_config {
        ocpus         = each.value.ocpus
        memory_in_gbs = each.value.memory_gb
      }

      source_details {
        source_type = "image"
        image_id    = data.oci_core_images.this.images[0].id
      }

      metadata = {
        user_data = base64encode(templatefile("${path.module}/cloud-init/${each.key}.yaml", {
          project     = local.project
          environment = local.environment
          brand       = local.env.brand
          region      = local.env.oci.region
        }))
      }

      create_vnic_details {
        assign_public_ip = false
        nsg_ids          = [oci_core_network_security_group.compute.id]
      }

      freeform_tags = local.default_tags
    }
  }
}
