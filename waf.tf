
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
      condition          = "true"
      condition_language = "JMESPATH"

      configurations {
        period_in_seconds          = 60
        requests_limit             = 100
        action_duration_in_seconds = 60
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
