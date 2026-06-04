
///////////////////////////////////////////////////////////[ OCI LOAD BALANCER ]/////////////////////////////////////////////////////

resource "oci_load_balancer_load_balancer" "this" {
  compartment_id = local.env.oci.compartment_ocid
  display_name   = "${local.project}-lb"
  shape          = "flexible"

  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 100
  }

  subnet_ids                 = oci_core_subnet.public[*].id
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

resource "oci_load_balancer_rule_set" "http_to_https_redirect" {
  count            = local.tls_enabled ? 1 : 0
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  name             = "http-to-https-redirect"

  items {
    action = "REDIRECT"
    redirect_uri {
      protocol = "HTTPS"
      host     = "{host}"
      path     = "{path}"
      query    = "{query}"
      port     = 443
    }
    response_code = 301
  }
}

resource "oci_load_balancer_listener" "http" {
  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "http-listener"
  default_backend_set_name = oci_load_balancer_backend_set.varnish.name
  port                     = 80
  protocol                 = "HTTP"
  # default_backend_set_name is required by OCI even when all traffic is redirected by the rule set
  rule_set_names = local.tls_enabled ? [oci_load_balancer_rule_set.http_to_https_redirect[0].name] : []
}

resource "oci_load_balancer_listener" "imgproxy" {
  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "imgproxy-listener"
  default_backend_set_name = oci_load_balancer_backend_set.frontend.name
  port                     = 8080
  protocol                 = "HTTP"
}

resource "oci_load_balancer_listener" "https" {
  count = local.tls_enabled ? 1 : 0

  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "https-listener"
  default_backend_set_name = oci_load_balancer_backend_set.varnish.name
  port                     = 443
  protocol                 = "HTTP2"

  ssl_configuration {
    certificate_name        = oci_load_balancer_certificate.this[0].certificate_name
    verify_peer_certificate = false
    protocols               = ["TLSv1.2", "TLSv1.3"]
    cipher_suite_name       = "oci-default-http2-tls-13-ssl-cipher-suite-v1"
  }
}
