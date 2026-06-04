
///////////////////////////////////////////////////////////[ OCI WAF ]/////////////////////////////////////////////////////

resource "oci_waf_web_app_firewall_policy" "this" {
  compartment_id = local.env.oci.compartment_ocid
  display_name   = "${local.project}-waf-policy"
  freeform_tags  = local.default_tags

  actions {
    name = "GEO_BLOCK"
    type = "RETURN_HTTP_RESPONSE"
    code = 403

    headers {
      name  = "X-WAF-Block"
      value = "geo"
    }

    body {
      type = "STATIC_TEXT"
      text = "Access denied"
    }
  }

  actions {
    name = "RATE_LIMIT"
    type = "RETURN_HTTP_RESPONSE"
    code = 429

    headers {
      name  = "Retry-After"
      value = "60"
    }

    body {
      type = "STATIC_TEXT"
      text = "Too many requests"
    }
  }

  request_rate_limiting {
    rules {
      name               = "rate-limit-per-ip"
      type               = "REQUEST_RATE_LIMITING"
      action_name        = "RATE_LIMIT"
      # Exclude the LB health check path so probe traffic is never rate-limited
      condition          = "http.request.url.path != '/${random_string.this["health_check"].result}'"
      condition_language = "JMESPATH"

      configurations {
        period_in_seconds          = local.env.waf.rate_limit.period_in_seconds
        requests_limit             = local.env.waf.rate_limit.requests_limit
        # Retry-After header above must match this value when updated
        action_duration_in_seconds = local.env.waf.rate_limit.action_duration_in_seconds
      }
    }
  }

  request_access_control {
    default_action_name = "ALLOW"

    rules {
      name               = "block-restricted-countries"
      type               = "ACCESS_CONTROL"
      action_name        = "GEO_BLOCK"
      condition          = "i_contains(['${join("', '", local.env.waf.restricted_countries)}'], http.request.geolocation.country_code)"
      condition_language = "JMESPATH"
    }
  }
}

resource "oci_waf_web_app_firewall" "this" {
  compartment_id             = local.env.oci.compartment_ocid
  display_name               = "${local.project}-waf"
  backend_type               = "LOAD_BALANCER"
  load_balancer_id           = oci_load_balancer_load_balancer.this.id
  web_app_firewall_policy_id = oci_waf_web_app_firewall_policy.this.id
  freeform_tags              = local.default_tags
}
