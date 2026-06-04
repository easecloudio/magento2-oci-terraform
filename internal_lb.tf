
///////////////////////////////////////////////////////////[ INTERNAL LOAD BALANCER ]/////////////////////////////////////////////////////

resource "oci_load_balancer_load_balancer" "internal" {
  compartment_id = local.env.oci.compartment_ocid
  display_name   = "${local.project}-internal-lb"
  shape          = "flexible"

  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 100
  }

  subnet_ids                 = oci_core_subnet.private[*].id
  is_private                 = true
  network_security_group_ids = [oci_core_network_security_group.internal_lb.id]
  freeform_tags              = local.default_tags
}

resource "oci_load_balancer_backend_set" "internal_frontend" {
  name             = "internal-frontend-backend-set"
  load_balancer_id = oci_load_balancer_load_balancer.internal.id
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "HTTP"
    port              = 8080
    url_path          = "/health"
    return_code       = 200
    interval_ms       = 10000
    timeout_in_millis = 3000
    retries           = 3
  }
}

resource "oci_load_balancer_listener" "internal_frontend" {
  load_balancer_id         = oci_load_balancer_load_balancer.internal.id
  name                     = "internal-frontend-listener"
  default_backend_set_name = oci_load_balancer_backend_set.internal_frontend.name
  port                     = 8080
  protocol                 = "HTTP"
}
