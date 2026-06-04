# Security Model

This document describes the security architecture of the `magento2-oci-terraform` project. It covers network topology, NSG rules, WAF policy, secrets management, IAM, TLS configuration, and hardening steps required before a production deployment.

---

## Network Isolation

All compute instances (Varnish and Frontend instance pools) run in **private subnets** with `prohibit_public_ip_on_vnic = true`. They have no public IP addresses and are unreachable directly from the internet.

The VCN uses two subnet tiers:

| Tier | Resource | Route table | Internet access |
|---|---|---|---|
| Public (`subnet-0`, `subnet-1`) | Load Balancer | Default (IGW) | Inbound and outbound |
| Private (`pvtsubnet-0`, `pvtsubnet-1`) | Compute, DB, Cache, NFS, OpenSearch | Private (NAT GW) | Outbound only via NAT |

The CIDR layout uses `/4` subdivision of the VCN CIDR block. With the default `172.35.0.0/16`, public subnets start at offset 0 and private subnets start at offset 8:

```
172.35.0.0/20    ← public subnet-0
172.35.16.0/20   ← public subnet-1
172.35.128.0/20  ← pvtsubnet-0
172.35.144.0/20  ← pvtsubnet-1
```

The **Internet Gateway** is attached only to the default route table used by public subnets. The **NAT Gateway** is attached to the private route table. Compute instances can make outbound calls (OS updates, OCI API) but nothing can initiate a connection to them from outside the VCN. The only operational ingress path is through the OCI Bastion service.

---

## Network Security Groups

Seven NSGs are defined in `security_groups.tf`. Each resource-level NSG tightly scopes which sources can reach it. Source types use `NETWORK_SECURITY_GROUP` references wherever possible, meaning the rule is tied to membership in another NSG rather than a CIDR range.

### lb-nsg

Protects the public-facing OCI Load Balancer.

| Direction | Source | Protocol | Port(s) |
|---|---|---|---|
| Ingress | `0.0.0.0/0` | TCP | 80 |
| Ingress | `0.0.0.0/0` | TCP | 443 |
| Egress | `0.0.0.0/0` | All | Any |

### compute-nsg

Protects Varnish and Frontend instance pools. Accepts traffic from the external LB on ports 80 and 8080, from the internal LB on port 8080, and from any host inside the VCN CIDR on port 80 (to allow Varnish-to-Frontend VCN-local traffic).

| Direction | Source | Protocol | Port(s) |
|---|---|---|---|
| Ingress | `lb-nsg` | TCP | 80 |
| Ingress | `lb-nsg` | TCP | 8080 |
| Ingress | `internal-lb-nsg` | TCP | 8080 |
| Ingress | VCN CIDR block | TCP | 80 |
| Egress | `0.0.0.0/0` | All | Any |

### internal-lb-nsg

Protects the internal load balancer that distributes Varnish → Frontend traffic. Ingress is restricted to compute instances; egress is limited to private subnet CIDRs only (not the full internet).

| Direction | Source / Destination | Protocol | Port(s) |
|---|---|---|---|
| Ingress | `compute-nsg` | TCP | 8080 |
| Egress | Each private subnet CIDR | All | Any |

The egress rule is a `for_each` over `local.private_subnet_cidrs`, so it expands automatically when `availability_domains_qty` increases.

### database-nsg

Protects the MySQL HeatWave instance.

| Direction | Source | Protocol | Port(s) |
|---|---|---|---|
| Ingress | `compute-nsg` | TCP | 3306 |
| Egress | `0.0.0.0/0` | All | Any |

### cache-nsg

Protects the OCI Cache (Redis) clusters.

| Direction | Source | Protocol | Port(s) |
|---|---|---|---|
| Ingress | `compute-nsg` | TCP | 6379 |
| Egress | `0.0.0.0/0` | All | Any |

### nfs-nsg

Protects the OCI File Storage mount targets.

| Direction | Source | Protocol | Port(s) |
|---|---|---|---|
| Ingress | `compute-nsg` | TCP | 2049 |
| Egress | `0.0.0.0/0` | All | Any |

### opensearch-nsg

Protects the OCI OpenSearch cluster. Port 9200 is the REST API; port 9300 is used for inter-node cluster communication and is restricted to members of the same NSG.

| Direction | Source | Protocol | Port(s) |
|---|---|---|---|
| Ingress | `compute-nsg` | TCP | 9200 |
| Ingress | `opensearch-nsg` (self) | TCP | 9300 |
| Egress | `0.0.0.0/0` | All | Any |

---

## WAF Rules

OCI WAF sits in front of the Load Balancer (`waf.tf`). The policy defines three action handlers and three rule categories.

### Actions

| Action name | HTTP status | Response header |
|---|---|---|
| `GEO_BLOCK` | 403 | `X-WAF-Block: geo` |
| `RATE_LIMIT` | 429 | `Retry-After: 60` |
| `ADMIN_BLOCK` | 403 | `X-WAF-Block: admin` |

### Geo-blocking

`block-restricted-countries` checks `http.request.geolocation.country_code` against a list defined in `waf.restricted_countries`. The default list in `developer.config.yaml` is:

```
CN, RU, IR, KP, SD, SY, CU
```

Any request whose country code appears in this list receives a `GEO_BLOCK` (403) response before any other rule is evaluated, because access control rules run before rate limiting in OCI WAF.

To narrow or expand the list, edit `waf.restricted_countries` in the appropriate environment config file and re-apply.

### Rate limiting

Two rate-limiting rules apply:

**Global per-IP limit** (`rate-limit-per-ip`): 100 requests per 60-second window per IP. Requests that exceed the limit receive a `RATE_LIMIT` (429) with `Retry-After: 60`. The LB health check path (a randomly generated 16-character token stored as a Vault secret) is **excluded** from this rule via a `!=` condition so probe traffic never triggers the limit.

**Admin path limit** (`rate-limit-admin-path`): 20 requests per 60-second window per IP, with a 300-second block duration. The condition matches any path that begins with the randomly generated admin path token (also 16 characters).

Both limits are configurable per environment through the `waf.rate_limit` and `waf.admin_rate_limit` blocks in the config YAML.

### Admin path IP restriction

The `restrict-admin-path` rule is created only when `waf.admin_allowed_cidrs` is non-empty. It is implemented as a `dynamic "rules"` block in Terraform:

```hcl
dynamic "rules" {
  for_each = length(local.env.waf.admin_allowed_cidrs) > 0 ? [1] : []
  ...
}
```

When active, any request whose path begins with the admin token and whose source IP is **not** in the allowed CIDR list receives an `ADMIN_BLOCK` (403). When `admin_allowed_cidrs` is empty (the default), the rule is omitted entirely and the admin path is accessible from any IP — appropriate for developer environments but not production.

To restrict admin access in production:

```yaml
waf:
  admin_allowed_cidrs:
    - "203.0.113.0/24"   # office egress CIDR
    - "198.51.100.5/32"  # VPN endpoint
```

---

## Secrets Management

Secrets are managed through OCI Vault (`secrets.tf`).

**Vault and key:** A `DEFAULT`-type vault and an AES-256 master key (`key_shape.algorithm = "AES"`, `key_shape.length = 32`) are created at apply time. Both resources carry `lifecycle { prevent_destroy = true }` to prevent accidental deletion via `terraform destroy`. Deletion requires an explicit OCI Console action with a minimum 7-day pending-deletion period.

**Secrets generated at apply time:**

| Secret name | Source | Purpose |
|---|---|---|
| `${project}-mysql-password` | `random_password.this["database"]` | MySQL user password |
| `${project}-redis-password` | `random_password.this["redis"]` | Redis AUTH password |
| `${project}-opensearch-password` | `random_password.this["opensearch"]` | OpenSearch user password |
| `${project}-admin-path` | `random_string.this["admin_path"]` | Magento admin URL segment |
| `${project}-health-check` | `random_string.this["health_check"]` | LB health check URL token |
| `${project}-opensearch-admin` | `random_string.this["opensearch_admin"]` | OpenSearch admin username |
| `${project}-security-header` | `random_uuid.this` | Internal security header UUID |

Secret names follow the pattern `${brand}-${codename}-${key}` in lowercase with hyphens, derived by `lower(replace(each.key, "_", "-"))`.

Passwords are 32 characters with upper, lower, numeric, and special characters (`!#$%&*()-_=+[]{}:?`). Strings are 16 alphanumeric characters. The security header is a standard UUID v4.

**Runtime access:** Compute instances fetch secrets at boot time using `oci secrets-cli get-secret-bundle-by-name` with `instance_principal` authentication (no credentials file required). This works because the dynamic group policy grants `read secret-bundles` and `use vaults` to all tagged instances in the compartment.

---

## IAM Model

IAM is defined in `identity.tf` and uses OCI's dynamic group + policy pattern so no credentials are embedded in instances.

**Dynamic group matching rule:**

```
Any {
  all {
    instance.compartment.id = '<compartment_ocid>',
    tag.oracle-tags.CreatedBy.value = 'terraform'
  }
}
```

An instance is a member if it is in the correct compartment **and** carries the `oracle-tags.CreatedBy = terraform` freeform tag. The `default_tags` local block applies this tag to all resources created by this project.

**Policy statements:**

| Statement | What it grants |
|---|---|
| `read secret-bundles` | Fetch secret values from the Vault |
| `use vaults` | Look up secrets by name within the Vault |
| `read objects` where bucket = `${project}-media-optimized` or `${project}-system` | Read-only access to the optimized media and system buckets |
| `manage objects` where bucket = `${project}-backup` | Full object CRUD on the backup bucket |
| `manage objects` where bucket = `${project}-media` | Full object CRUD on the media bucket |
| `use file-family` | Mount NFS file systems via OCI File Storage |
| `read instance-family` | Read instance metadata (used by cloud-init/Ansible) |

The `manage objects` grants on `media` and `backup` are intentionally scoped by bucket name, not compartment-wide, so instances cannot access other Object Storage buckets in the compartment.

---

## TLS

TLS terminates at the OCI Load Balancer. There is no TLS between the LB and Varnish; traffic inside the VCN is plaintext.

**Supplying certificates:**

```bash
export TF_VAR_ssl_certificate_pem="$(cat fullchain.pem)"
export TF_VAR_ssl_private_key_pem="$(cat privkey.pem)"
terraform apply
```

Both variables are marked `sensitive = true` and are never written to state in plaintext. The certificate resource is conditional (`count = var.ssl_certificate_pem != "" ? 1 : 0`), so applying without a certificate leaves the LB on HTTP only.

**Listener configuration (when TLS is enabled):**

- Protocol: `HTTP2`
- TLS versions: `TLSv1.2`, `TLSv1.3`
- Cipher suite: `oci-default-http2-tls-13-ssl-cipher-suite-v1`
- Backend certificate verification: disabled (traffic to Varnish is internal plaintext)
- HTTP → HTTPS redirect: 301 redirect rule set applied to the port-80 listener

---

## Instance Hardening

The following controls apply to every compute instance at launch time:

- **No public IPs.** Private subnets have `prohibit_public_ip_on_vnic = true`. Instances cannot be assigned a public IP even manually.
- **OS packages upgraded on boot.** `cloud-init` is configured with `package_upgrade: true`, so the instance installs all available security updates during its first boot before Ansible runs.
- **SSH keys are optional.** `var.ssh_public_key` defaults to `""`. If left unset, no SSH key is injected and password authentication is disabled by the base image. Direct SSH is then impossible even through the Bastion.
- **Bastion is the only ops ingress.** The OCI Bastion service targets `oci_core_subnet.private[0]` (the first private subnet). Sessions require an IAM principal with `manage bastion-sessions` permission and a valid CIDR in `var.bastion_allowed_cidrs`.

---

## Production Hardening Checklist

Before promoting to a staging or production environment, complete the following:

- **Restrict WAF admin access.** Set `waf.admin_allowed_cidrs` in the environment config to your office egress CIDRs and/or VPN endpoint IPs. Leaving this empty means the admin path is reachable from any IP (rate-limited, but not IP-restricted).
- **Restrict Bastion access.** Set `var.bastion_allowed_cidrs` (via `terraform.tfvars` or environment variable) to your ops team CIDRs. The default empty list means the Bastion accepts sessions from `0.0.0.0/0`.
- **Supply a real TLS certificate.** Set `TF_VAR_ssl_certificate_pem` and `TF_VAR_ssl_private_key_pem` before applying. Use a certificate from your CA or a Let's Encrypt cert managed externally. Without this, the LB operates on HTTP only.
- **Review the geo-block list.** The default `waf.restricted_countries` list is appropriate for many deployments, but review it against your actual customer geography. Blocking a country where legitimate customers reside will silently drop their traffic with a 403.
- **Enable OCI Logging for access logs.** Nginx and Varnish access log forwarding to OCI Logging is not yet automated by this Terraform project. Configure log groups and log sources manually in the OCI Console, or add `oci_logging_log` and `oci_logging_log_group` resources to a future `logging.tf`.
- **Set SSH public key or remove it entirely.** If your ops workflow requires SSH via Bastion, set `var.ssh_public_key` to a key controlled by your team. If you manage instances solely through OCI Run Command and cloud-init, leave it empty.
