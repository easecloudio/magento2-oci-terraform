
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

  request_protection {
    rules {
      name                       = "block-restricted-countries"
      type                       = "PROTECTION"
      action_name                = "GEO_BLOCK"
      is_body_inspection_enabled = false
      condition                  = "i_contains(keys(http.request.headers), 'x-country') && i_contains(['${join("', '", local.env.waf.restricted_countries)}'], http.request.headers['x-country'][0])"

      protection_capabilities {
        key     = "9300000"
        version = 1
      }
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
