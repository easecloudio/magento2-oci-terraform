# Security Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all security, correctness, and operational gaps identified in the code review.

**Architecture:** Eighteen targeted changes across networking, WAF, IAM, secrets, cloud-init, monitoring, DNS, and CI. Each task is independent unless a dependency is noted. Private-subnet networking is the foundation — tasks 1–4 build it; remaining tasks are parallel.

**Tech Stack:** Terraform 1.9+, OCI provider ~> 6.0, GitHub Actions

---

### Task 1: Add private subnets and NAT gateway

**Files:**
- Modify: `vpc_network.tf`

Private subnets are the prerequisite for Tasks 2–4. All backend services (MySQL, Redis, OpenSearch, NFS, compute) must move off public subnets.

**Step 1: Add private subnets, NAT gateway, and private route table to `vpc_network.tf`**

Append after the existing `oci_core_dhcp_options` resource:

```hcl
resource "oci_core_nat_gateway" "this" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-ngw"
  freeform_tags  = local.default_tags
}

resource "oci_core_route_table" "private" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-private-rt"
  freeform_tags  = local.default_tags

  route_rules {
    network_entity_id = oci_core_nat_gateway.this.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

resource "oci_core_subnet" "private" {
  count = local.env.vcn.availability_domains_qty

  compartment_id             = local.env.oci.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = cidrsubnet(local.env.vcn.cidr_block, 4, count.index + 8)
  availability_domain        = data.oci_identity_availability_domains.this.availability_domains[count.index].name
  display_name               = "${local.project}-private-subnet-${count.index}"
  dns_label                  = "pvtsubnet${count.index}"
  prohibit_public_ip_on_vnic = true
  security_list_ids          = [oci_core_vcn.this.default_security_list_id]
  route_table_id             = oci_core_route_table.private.id
  freeform_tags              = local.default_tags
}
```

The `cidrsubnet(..., 4, count.index + 8)` offset avoids collision with the existing public subnets (index 0–1).

**Step 2: Validate**

```bash
terraform fmt && terraform validate
```

Expected: `Success! The configuration is valid.`

**Step 3: Commit**

```bash
git add vpc_network.tf
git commit -m "feat: add private subnets and NAT gateway"
```

---

### Task 2: Add OpenSearch NSG

**Files:**
- Modify: `security_groups.tf`

OpenSearch must have its own NSG rather than sharing the compute NSG.

**Step 1: Append the OpenSearch NSG block to `security_groups.tf`**

```hcl
# # ---------------------------------------------------------------------------------------------------------------------#
# OpenSearch NSG — allows 9200/9300 from compute only
# # ---------------------------------------------------------------------------------------------------------------------#
resource "oci_core_network_security_group" "opensearch" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-opensearch-nsg"
  freeform_tags  = local.default_tags
}

resource "oci_core_network_security_group_security_rule" "opensearch_ingress_api" {
  network_security_group_id = oci_core_network_security_group.opensearch.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.compute.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 9200
      max = 9200
    }
  }
}

resource "oci_core_network_security_group_security_rule" "opensearch_ingress_cluster" {
  network_security_group_id = oci_core_network_security_group.opensearch.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.opensearch.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 9300
      max = 9300
    }
  }
}

resource "oci_core_network_security_group_security_rule" "opensearch_egress_all" {
  network_security_group_id = oci_core_network_security_group.opensearch.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}
```

**Step 2: Validate**

```bash
terraform fmt && terraform validate
```

**Step 3: Commit**

```bash
git add security_groups.tf
git commit -m "feat: add dedicated OpenSearch NSG"
```

---

### Task 3: Move all backends to private subnets

**Depends on:** Task 1 (private subnets), Task 2 (OpenSearch NSG)

**Files:**
- Modify: `database.tf`
- Modify: `cache.tf`
- Modify: `search.tf`
- Modify: `filesystem.tf`

**Step 1: Update `database.tf`**

Change:
```hcl
subnet_id = oci_core_subnet.public[0].id
```
To:
```hcl
subnet_id = oci_core_subnet.private[0].id
```

**Step 2: Update `cache.tf`**

Change:
```hcl
subnet_id = oci_core_subnet.public[0].id
```
To:
```hcl
subnet_id = oci_core_subnet.private[0].id
```

**Step 3: Update `search.tf`**

Change two attributes:
```hcl
subnet_id = oci_core_subnet.private[0].id
nsg_id    = oci_core_network_security_group.opensearch.id
```

**Step 4: Update `filesystem.tf`**

In both `oci_file_storage_mount_target`:
```hcl
subnet_id = oci_core_subnet.private[0].id
```

**Step 5: Validate**

```bash
terraform fmt && terraform validate
```

**Step 6: Commit**

```bash
git add database.tf cache.tf search.tf filesystem.tf
git commit -m "fix: move backend services to private subnets"
```

---

### Task 4: Move compute to private subnets, remove public IPs, fix multi-AD placement

**Depends on:** Task 1 (private subnets)

**Files:**
- Modify: `compute_profile.tf`
- Modify: `compute.tf`

**Step 1: Update `compute_profile.tf`**

In `create_vnic_details`, change:
```hcl
create_vnic_details {
  assign_public_ip = false
  nsg_ids          = [oci_core_network_security_group.compute.id]
  subnet_id        = oci_core_subnet.private[0].id
}
```

**Step 2: Update `compute.tf` — add second AD placement**

Replace the single `placement_configurations` block with two:

```hcl
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

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [size]
  }
}
```

**Step 3: Validate**

```bash
terraform fmt && terraform validate
```

**Step 4: Commit**

```bash
git add compute_profile.tf compute.tf
git commit -m "fix: move compute to private subnets, remove public IPs, span both ADs"
```

---

### Task 5: Fix LB to span both public subnets

**Files:**
- Modify: `load_balancer.tf`

**Step 1: Update subnet_ids**

Change:
```hcl
subnet_ids = [oci_core_subnet.public[0].id]
```
To:
```hcl
subnet_ids = oci_core_subnet.public[*].id
```

**Step 2: Validate**

```bash
terraform fmt && terraform validate
```

**Step 3: Commit**

```bash
git add load_balancer.tf
git commit -m "fix: load balancer spans both ADs via both public subnets"
```

---

### Task 6: Fix WAF geo-block to use built-in geolocation

**Files:**
- Modify: `waf.tf`

The current rule reads an `x-country` request header which a caller can spoof. OCI WAF exposes `http.request.geolocation.country_code` which is derived from OCI's own IP intelligence, not from the request.

**Step 1: Replace the `request_protection` block in `waf.tf`**

Replace the entire `request_protection` block:

```hcl
  request_access_control {
    default_action_name = "ALLOW"

    rules {
      name        = "block-restricted-countries"
      type        = "ACCESS_CONTROL"
      action_name = "GEO_BLOCK"
      condition   = "i_contains(['${join("', '", local.env.waf.restricted_countries)}'], http.request.geolocation.country_code)"
      condition_language = "JMESPATH"
    }
  }
```

Also remove the `protection_capabilities` block — it is not applicable to `ACCESS_CONTROL` rules. The final `waf.tf` should look like:

```hcl
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
```

**Step 2: Validate**

```bash
terraform fmt && terraform validate
```

**Step 3: Commit**

```bash
git add waf.tf
git commit -m "fix: WAF geo-block uses built-in geolocation, not spoofable x-country header"
```

---

### Task 7: Add HTTPS listener and TLS certificate

**Files:**
- Create: `tls.tf`
- Modify: `load_balancer.tf`

OCI Load Balancer TLS termination uses a certificate uploaded to the LB. In this setup, the domain is configured in the YAML. The certificate resource references `var.ssl_certificate_pem` — operators must supply this (e.g., from Let's Encrypt / ACME, or OCI Certificates service). We wire up the listener so it is ready; supplying actual cert content is a day-2 operation.

**Step 1: Create `tls.tf`**

```hcl
///////////////////////////////////////////////////////////[ TLS CERTIFICATE ]/////////////////////////////////////////////////////

# Supply actual PEM content via TF_VAR_ssl_certificate_pem and TF_VAR_ssl_private_key_pem
# environment variables, or from a secrets manager in CI.
variable "ssl_certificate_pem" {
  description = "PEM-encoded certificate chain for the domain"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ssl_private_key_pem" {
  description = "PEM-encoded private key for the domain"
  type        = string
  sensitive   = true
  default     = ""
}

resource "oci_load_balancer_certificate" "this" {
  count = var.ssl_certificate_pem != "" ? 1 : 0

  load_balancer_id   = oci_load_balancer_load_balancer.this.id
  certificate_name   = "${local.project}-cert"
  public_certificate = var.ssl_certificate_pem
  private_key        = var.ssl_private_key_pem
}
```

**Step 2: Update `load_balancer.tf` — uncomment and wire the HTTPS listener**

Replace the commented-out HTTPS block with an active resource that is conditional on the certificate existing:

```hcl
resource "oci_load_balancer_listener" "https" {
  count = length(oci_load_balancer_certificate.this) > 0 ? 1 : 0

  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "https-listener"
  default_backend_set_name = oci_load_balancer_backend_set.varnish.name
  port                     = 443
  protocol                 = "HTTP"

  ssl_configuration {
    certificate_name        = oci_load_balancer_certificate.this[0].certificate_name
    verify_peer_certificate = false
  }
}
```

Remove the old commented-out HTTPS listener block.

**Step 3: Validate**

```bash
terraform fmt && terraform validate
```

**Step 4: Commit**

```bash
git add tls.tf load_balancer.tf
git commit -m "feat: add HTTPS listener with conditional TLS cert resource"
```

---

### Task 8: Fix Events rule condition

**Files:**
- Modify: `events.tf`

The `resourceName` field on `com.oraclecloud.objectstorage.createobject` events is the object key, not the bucket name. Bucket name is in `additionalDetails.bucketName`.

**Step 1: Update the `condition` in `oci_events_rule.release_deploy`**

Replace:
```hcl
  condition = jsonencode({
    eventType = ["com.oraclecloud.objectstorage.createobject"]
    data = {
      resourceName = ["${local.project}-system"]
      additionalDetails = {
        namespaceName = [data.oci_objectstorage_namespace.this.namespace]
      }
    }
  })
```

With:
```hcl
  condition = jsonencode({
    eventType = ["com.oraclecloud.objectstorage.createobject"]
    data = {
      additionalDetails = {
        bucketName    = ["${local.project}-system"]
        namespaceName = [data.oci_objectstorage_namespace.this.namespace]
      }
    }
  })
```

**Step 2: Validate**

```bash
terraform fmt && terraform validate
```

**Step 3: Commit**

```bash
git add events.tf
git commit -m "fix: events rule uses bucketName not resourceName for object storage trigger"
```

---

### Task 9: Rename MARIADB_PASSWORD to MYSQL_PASSWORD

**Files:**
- Modify: `secrets.tf`

**Step 1: Rename the key in `locals.secrets`**

In `secrets.tf`, change:
```hcl
MARIADB_PASSWORD = random_password.this["database"].result
```
To:
```hcl
MYSQL_PASSWORD = random_password.this["database"].result
```

**Step 2: Validate**

```bash
terraform fmt && terraform validate
```

**Step 3: Commit**

```bash
git add secrets.tf
git commit -m "fix: rename MARIADB_PASSWORD secret to MYSQL_PASSWORD"
```

Note: if this vault secret already exists in OCI, Terraform will destroy and recreate it (new name = new resource). Plan carefully before applying to an existing environment.

---

### Task 10: Scope identity policy and dynamic group

**Files:**
- Modify: `identity.tf`

Two changes:
1. Split `manage objects` into `read objects` for all buckets + `manage objects` scoped to backup only.
2. Add a tag condition to the dynamic group so it only matches Terraform-managed instances.

**Step 1: Update `identity.tf`**

Replace the file content:

```hcl
///////////////////////////////////////////////////////////[ IDENTITY ]/////////////////////////////////////////////////////

resource "oci_identity_dynamic_group" "compute" {
  compartment_id = local.env.oci.tenancy_ocid
  name           = "${local.project}-compute-dg"
  description    = "Dynamic group for ${local.project} compute instances"
  matching_rule  = "Any {all {instance.compartment.id = '${local.env.oci.compartment_ocid}', tag.oracle-tags.CreatedBy.value = 'terraform'}}"
}

resource "oci_identity_policy" "compute" {
  compartment_id = local.env.oci.compartment_ocid
  name           = "${local.project}-compute-policy"
  description    = "Allows compute instances to access vault, object storage, and file storage"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to read secret-bundles in compartment id ${local.env.oci.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to read objects in compartment id ${local.env.oci.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to manage objects in compartment id ${local.env.oci.compartment_ocid} where target.bucket.name = '${local.project}-backup'",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to manage objects in compartment id ${local.env.oci.compartment_ocid} where target.bucket.name = '${local.project}-media'",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to use file-family in compartment id ${local.env.oci.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.compute.name} to read instance-family in compartment id ${local.env.oci.compartment_ocid}",
  ]
}
```

The dynamic group tag condition `tag.oracle-tags.CreatedBy.value = 'terraform'` uses the Oracle-managed tag namespace that OCI applies automatically. Adjust if your tenancy uses a different defined tag scheme.

**Step 2: Validate**

```bash
terraform fmt && terraform validate
```

**Step 3: Commit**

```bash
git add identity.tf
git commit -m "fix: scope IAM policy to specific buckets, narrow dynamic group with tag condition"
```

---

### Task 11: Add prevent_destroy on KMS vault and key

**Files:**
- Modify: `secrets.tf`

**Step 1: Add lifecycle blocks to `oci_kms_vault` and `oci_kms_key`**

```hcl
resource "oci_kms_vault" "this" {
  compartment_id = local.env.oci.compartment_ocid
  display_name   = "${local.project}-vault"
  vault_type     = "DEFAULT"
  freeform_tags  = local.default_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_kms_key" "this" {
  compartment_id      = local.env.oci.compartment_ocid
  display_name        = "${local.project}-master-key"
  management_endpoint = oci_kms_vault.this.management_endpoint
  freeform_tags       = local.default_tags

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  lifecycle {
    prevent_destroy = true
  }
}
```

**Step 2: Validate**

```bash
terraform fmt && terraform validate
```

**Step 3: Commit**

```bash
git add secrets.tf
git commit -m "fix: prevent_destroy on KMS vault and master key"
```

---

### Task 12: Fix NFS identity squash

**Files:**
- Modify: `filesystem.tf`

**Step 1: Change identity_squash in the export_options block**

Change:
```hcl
identity_squash = "NONE"
```
To:
```hcl
identity_squash = "ROOT"
```

**Step 2: Validate**

```bash
terraform fmt && terraform validate
```

**Step 3: Commit**

```bash
git add filesystem.tf
git commit -m "fix: NFS export uses ROOT identity squash instead of NONE"
```

---

### Task 13: Fix cloud-init — package upgrades and Ansible path

**Files:**
- Modify: `cloud-init/frontend.yaml`
- Modify: `cloud-init/varnish.yaml`

Two fixes: enable security upgrades; use an explicit PATH so Ansible is callable after pipx installs it.

**Step 1: Update `cloud-init/frontend.yaml`**

Replace the full content:

```yaml
#cloud-config
package_update: true
package_upgrade: true

packages:
  - jq
  - curl
  - unzip
  - python3-pip
  - python3-venv

runcmd:
  - |
    hostnamectl set-hostname frontend.${brand}.internal
    echo "127.0.0.1 frontend.${brand}.internal" >> /etc/hosts

  - |
    curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh | bash -s -- --accept-all-defaults

  - |
    pip3 install pipx --quiet
    /usr/local/bin/pipx install ansible-core
    export PATH="$PATH:/root/.local/bin"

  - |
    PRIVATE_IP=$(curl -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/metadata/privateIp 2>/dev/null || true)
    echo "Instance IP: $PRIVATE_IP" >> /var/log/cloud-init-custom.log

final_message: "Frontend instance initialized in ${project} (${environment})"
```

**Step 2: Update `cloud-init/varnish.yaml`**

Replace the full content:

```yaml
#cloud-config
package_update: true
package_upgrade: true

packages:
  - jq
  - curl
  - unzip
  - varnish
  - python3-pip
  - python3-venv

runcmd:
  - |
    hostnamectl set-hostname varnish.${brand}.internal
    echo "127.0.0.1 varnish.${brand}.internal" >> /etc/hosts

  - |
    curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh | bash -s -- --accept-all-defaults

  - |
    pip3 install pipx --quiet
    /usr/local/bin/pipx install ansible-core
    export PATH="$PATH:/root/.local/bin"

  - |
    PRIVATE_IP=$(curl -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/metadata/privateIp 2>/dev/null || true)
    echo "Varnish instance IP: $PRIVATE_IP" >> /var/log/cloud-init-custom.log

final_message: "Varnish instance initialized in ${project} (${environment})"
```

**Step 3: Validate Terraform still renders templates correctly**

```bash
terraform fmt && terraform validate
```

**Step 4: Commit**

```bash
git add cloud-init/frontend.yaml cloud-init/varnish.yaml
git commit -m "fix: enable package_upgrade in cloud-init, fix Ansible PATH after pipx install"
```

---

### Task 14: Add monitoring alarms and email subscription

**Files:**
- Modify: `monitoring.tf`
- Modify: `events.tf` (add email subscription to existing topic)

**Step 1: Add email subscription to `events.tf`**

Append to `events.tf`:

```hcl
resource "oci_ons_subscription" "admin_email" {
  compartment_id = local.env.oci.compartment_ocid
  topic_id       = oci_ons_notification_topic.default.id
  protocol       = "EMAIL"
  endpoint       = local.env.admin_email
  freeform_tags  = local.default_tags
}
```

**Step 2: Replace `monitoring.tf` with additional alarms**

```hcl
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
```

**Step 3: Validate**

```bash
terraform fmt && terraform validate
```

**Step 4: Commit**

```bash
git add monitoring.tf events.tf
git commit -m "feat: add memory/LB alarms and email subscription to notification topic"
```

---

### Task 15: Add DNS records

**Files:**
- Modify: `dns.tf`
- Modify: `service_discovery.tf`

**Step 1: Add public DNS records to `dns.tf`**

Append to `dns.tf`:

```hcl
resource "oci_dns_rrset" "apex" {
  zone_name_or_id = oci_dns_zone.public.id
  domain          = local.env.domain
  rtype           = "A"
  scope           = "GLOBAL"

  items {
    domain = local.env.domain
    rtype  = "A"
    ttl    = 300
    rdata  = oci_load_balancer_load_balancer.this.ip_addresses[0].ip_address
  }
}

resource "oci_dns_rrset" "www" {
  zone_name_or_id = oci_dns_zone.public.id
  domain          = "www.${local.env.domain}"
  rtype           = "CNAME"
  scope           = "GLOBAL"

  items {
    domain = "www.${local.env.domain}"
    rtype  = "CNAME"
    ttl    = 300
    rdata  = "${local.env.domain}."
  }
}
```

**Step 2: Add private DNS records for internal services to `service_discovery.tf`**

Append to `service_discovery.tf`:

```hcl
resource "oci_dns_rrset" "mysql" {
  zone_name_or_id = oci_dns_zone.internal.id
  domain          = "mysql.${local.env.brand}.internal"
  rtype           = "CNAME"
  view_id         = oci_dns_view.internal.id
  scope           = "PRIVATE"

  items {
    domain = "mysql.${local.env.brand}.internal"
    rtype  = "CNAME"
    ttl    = 60
    rdata  = "${oci_mysql_mysql_db_system.this.endpoints[0].hostname}."
  }
}

resource "oci_dns_rrset" "redis" {
  for_each        = oci_redis_redis_cluster.this
  zone_name_or_id = oci_dns_zone.internal.id
  domain          = "redis-${each.key}.${local.env.brand}.internal"
  rtype           = "A"
  view_id         = oci_dns_view.internal.id
  scope           = "PRIVATE"

  items {
    domain = "redis-${each.key}.${local.env.brand}.internal"
    rtype  = "A"
    ttl    = 60
    rdata  = each.value.primary_endpoint_ip_address
  }
}

resource "oci_dns_rrset" "opensearch" {
  zone_name_or_id = oci_dns_zone.internal.id
  domain          = "opensearch.${local.env.brand}.internal"
  rtype           = "CNAME"
  view_id         = oci_dns_view.internal.id
  scope           = "PRIVATE"

  items {
    domain = "opensearch.${local.env.brand}.internal"
    rtype  = "CNAME"
    ttl    = 60
    rdata  = "${oci_opensearch_opensearch_cluster.this.opensearch_fqdn}."
  }
}
```

**Step 3: Validate**

```bash
terraform fmt && terraform validate
```

**Step 4: Commit**

```bash
git add dns.tf service_discovery.tf
git commit -m "feat: add public A/CNAME records and private DNS records for internal services"
```

---

### Task 16: Improve CI with tflint and Checkov

**Files:**
- Modify: `.github/workflows/main.yml`

**Step 1: Replace `.github/workflows/main.yml`**

```yaml
name: Terraform CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "~> 1.9"

      - name: Terraform Format Check
        run: terraform fmt -check -recursive

      - name: Terraform Init
        run: terraform init -backend=false

      - name: Select workspace
        run: terraform workspace select developer || terraform workspace new developer

      - name: Terraform Validate
        run: terraform validate

  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: terraform-linters/setup-tflint@v4
        with:
          tflint_version: latest

      - name: tflint init
        run: tflint --init

      - name: tflint
        run: tflint --recursive

  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Checkov scan
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: .
          framework: terraform
          soft_fail: false
          skip_check: CKV_OCI_1,CKV2_OCI_2
```

The two skipped Checkov checks (`CKV_OCI_1`, `CKV2_OCI_2`) are for SSH ingress on the default security list — the project uses NSGs, not security lists, so those are safe to skip.

**Step 2: Commit**

```bash
git add .github/workflows/main.yml
git commit -m "ci: add tflint and Checkov security scanning jobs"
```

---

### Final: Validate the full set of changes

```bash
terraform fmt -recursive && terraform validate
```

Expected: all files formatted, `Success! The configuration is valid.`
