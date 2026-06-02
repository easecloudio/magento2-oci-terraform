
///////////////////////////////////////////////////////////[ OCI LOAD BALANCER ]/////////////////////////////////////////////////////

resource "oci_load_balancer_load_balancer" "this" {
  compartment_id = local.env.oci.compartment_ocid
  display_name   = "${local.project}-lb"
  shape          = "flexible"

  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 100
  }

  subnet_ids                 = [oci_core_subnet.public[0].id]
  is_private                 = false
  network_security_group_ids = [oci_core_network_security_group.lb.id]
  freeform_tags              = local.default_tags
}

resource "oci_load_balancer_backend_set" "varnish" {
  name             = "varnish-backend-set"
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "HTTP"
    port              = 80
    url_path          = "/${random_string.this["health_check"].result}"
    return_code       = 200
    interval_ms       = 10000
    timeout_in_millis = 3000
    retries           = 3
  }
}

resource "oci_load_balancer_backend_set" "frontend" {
  name             = "frontend-backend-set"
  load_balancer_id = oci_load_balancer_load_balancer.this.id
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

resource "oci_load_balancer_listener" "http" {
  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "http-listener"
  default_backend_set_name = oci_load_balancer_backend_set.varnish.name
  port                     = 80
  protocol                 = "HTTP"
}

resource "oci_load_balancer_listener" "imgproxy" {
  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "imgproxy-listener"
  default_backend_set_name = oci_load_balancer_backend_set.frontend.name
  port                     = 8080
  protocol                 = "HTTP"
}

# HTTPS listener (port 443) requires certificate resources from dns.tf/tls.tf.
# Wire in after those files are added:
#
# resource "oci_load_balancer_listener" "https" {
#   load_balancer_id         = oci_load_balancer_load_balancer.this.id
#   name                     = "https-listener"
#   default_backend_set_name = oci_load_balancer_backend_set.varnish.name
#   port                     = 443
#   protocol                 = "HTTP"
#
#   ssl_configuration {
#     certificate_name        = oci_load_balancer_certificate.this.certificate_name
#     verify_peer_certificate = false
#   }
# }
