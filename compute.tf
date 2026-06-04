
///////////////////////////////////////////////////////////[ INSTANCE POOL + AUTOSCALING ]/////////////////////////////////////////////////////

resource "oci_core_instance_pool" "this" {
  for_each                  = local.env.compute
  compartment_id            = local.env.oci.compartment_ocid
  instance_configuration_id = oci_core_instance_configuration.this[each.key].id
  size                      = each.value.desired_capacity
  display_name              = "${local.project}-${each.key}-pool"
  freeform_tags             = local.default_tags

  dynamic "placement_configurations" {
    for_each = range(local.env.vcn.availability_domains_qty)
    content {
      availability_domain = data.oci_identity_availability_domains.this.availability_domains[placement_configurations.value].name
      primary_subnet_id   = oci_core_subnet.private[placement_configurations.value].id
      primary_vnic_subnets {
        subnet_id = oci_core_subnet.private[placement_configurations.value].id
      }
    }
  }

  load_balancers {
    load_balancer_id = oci_load_balancer_load_balancer.this.id
    backend_set_name = local.pool_lb_config[each.key].backend_set_name
    port             = local.pool_lb_config[each.key].port
    vnic_selection   = "PrimaryVnic"
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [size]
  }
}

resource "oci_autoscaling_auto_scaling_configuration" "this" {
  for_each             = local.env.compute
  compartment_id       = local.env.oci.compartment_ocid
  display_name         = "${local.project}-${each.key}-asc"
  cool_down_in_seconds = local.env.autoscaling.cooldown_in_seconds
  is_enabled           = true

  auto_scaling_resources {
    id   = oci_core_instance_pool.this[each.key].id
    type = "instancePool"
  }

  policies {
    policy_type  = "threshold"
    display_name = "${local.project}-${each.key}-scale-policy"

    capacity {
      initial = each.value.desired_capacity
      min     = each.value.min_size
      max     = each.value.max_size
    }

    rules {
      display_name = "scale-out-cpu"
      action {
        type  = "CHANGE_COUNT_BY"
        value = 1
      }
      metric {
        metric_type = "CPU_UTILIZATION"
        threshold {
          operator = "GT"
          value    = local.env.autoscaling.out_threshold_percent
        }
      }
    }

    rules {
      display_name = "scale-in-cpu"
      action {
        type  = "CHANGE_COUNT_BY"
        value = -1
      }
      metric {
        metric_type = "CPU_UTILIZATION"
        threshold {
          operator = "LT"
          value    = local.env.autoscaling.in_threshold_percent
        }
      }
    }
  }
}
