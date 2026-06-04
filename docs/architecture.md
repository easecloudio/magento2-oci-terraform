# Architecture

This document describes the infrastructure provisioned by this Terraform project for hosting Magento 2 on Oracle Cloud Infrastructure (OCI).

---

## Overview

The stack uses a two-tier compute architecture. Public traffic is inspected by OCI WAF before reaching a public-facing flexible load balancer. That load balancer distributes requests across a Varnish instance pool, which handles HTTP caching. Cache misses are forwarded by Varnish to a private internal load balancer, which balances across the PHP-FPM/Nginx frontend instance pool. The frontend tier connects to MySQL HeatWave (database), two OCI Cache Redis clusters (session and page cache), OCI OpenSearch (catalog search), OCI File Storage (shared NFS mounts), and OCI Object Storage (media, backups). All compute instances run on OCI Ampere A1 Flex ARM VMs in private subnets with no public IP addresses. Operator access is provided exclusively through the OCI Bastion service.

---

## Network Topology

### VCN

| Parameter | Value |
|---|---|
| CIDR block | `172.35.0.0/16` (configurable per environment) |
| DNS label | `vcn` (configurable) |
| DHCP server type | `VcnLocalPlusInternet` |
| DHCP search domain | `<dns_label>.oraclevcn.com` |

The VCN contains an Internet Gateway for public subnet outbound/inbound traffic and a NAT Gateway for private subnet outbound-only traffic.

### Subnet layout

Subnets are created in a `for_each` loop over `vcn.availability_domains_qty` (2 in developer/staging, 2 in production). Public and private subnets are carved from the VCN CIDR using `/4` nibble offsets:

- **Public subnets** — `cidrsubnet(cidr, 4, 0)`, `cidrsubnet(cidr, 4, 1)`, … (indices 0, 1, …)
- **Private subnets** — `cidrsubnet(cidr, 4, 8)`, `cidrsubnet(cidr, 4, 9)`, … (indices 8, 9, …)

With `172.35.0.0/16` as the base and a `/4` offset, each subnet is a `/20` block (~4,094 hosts). For a two-AD deployment:

| Subnet | CIDR | Route table |
|---|---|---|
| Public AD-0 | `172.35.0.0/20` | Default (IGW) |
| Public AD-1 | `172.35.16.0/20` | Default (IGW) |
| Private AD-0 | `172.35.128.0/20` | Private (NAT) |
| Private AD-1 | `172.35.144.0/20` | Private (NAT) |

Private subnets set `prohibit_public_ip_on_vnic = true`, so no VNIC on those subnets can acquire a public IP.

### Route tables

- **Default route table** — used by public subnets; routes `0.0.0.0/0` to the Internet Gateway.
- **Private route table** — used by private subnets; routes `0.0.0.0/0` to the NAT Gateway (egress-only).

---

## Traffic Flow

The following describes the path of an inbound HTTPS request in a TLS-enabled environment. Port numbers match the listener and backend set configurations in `load_balancer.tf`, `internal_lb.tf`, and `waf.tf`.

```
Internet
  │
  │  TCP 443 (or 80 → 301 redirect to 443)
  ▼
OCI WAF (attached to public LB)
  │  Evaluates: geo-block, rate-limit-per-ip, restrict-admin-path, rate-limit-admin-path
  │  Block actions return HTTP 403 / 429 and terminate the connection
  ▼
Public Load Balancer (flexible, 10–100 Mbps, public subnets)
  │  HTTPS listener :443, protocol HTTP2, TLSv1.2/1.3
  │  Backend set: varnish-backend-set, policy ROUND_ROBIN
  │  Health check: GET /<health_check_token> :80 → expect HTTP 200
  ▼
Varnish Instance Pool (private subnets, port 80)
  │  ARM A1 Flex VMs — serve from cache or forward on miss
  │
  │  [cache miss]
  │
  │  TCP 8080
  ▼
Private Internal Load Balancer (flexible, private subnets, no WAF)
  │  HTTP listener :8080, idle timeout 600 s
  │  Backend set: internal-frontend-backend-set, policy ROUND_ROBIN
  │  Health check: GET /health :8080 → expect HTTP 200
  ▼
Frontend Instance Pool (private subnets, port 8080)
  │  ARM A1 Flex VMs — Nginx + PHP-FPM (Magento 2 application)
  │
  ├── TCP 3306  → MySQL HeatWave (private subnet AD-0)
  ├── TCP 6379  → Redis session cluster  (private subnet, configured AD)
  ├── TCP 6379  → Redis cache cluster    (private subnet, configured AD)
  ├── TCP 9200  → OCI OpenSearch (REST API)
  ├── TCP 2049  → OCI File Storage (NFSv4 mount targets, per-AD)
  └── HTTPS     → OCI Object Storage (media, backup buckets via OCI SDK)
```

The `imgproxy` listener on the public LB at port 8080 bypasses Varnish entirely and routes directly to the `frontend-backend-set` (also port 8080) for image transformation requests that must not be cached through Varnish.

---

## Compute Tier

### Shape

All instance pools use `VM.Standard.A1.Flex` (OCI Ampere A1, 64-bit ARM). Shape config (OCPUs and memory in GBs) is defined per environment and per pool in the `compute` section of each `*.config.yaml`.

| Environment | Pool | OCPUs | Memory (GB) | min / desired / max |
|---|---|---|---|---|
| developer | varnish | 2 | 12 | 2 / 2 / 8 |
| developer | frontend | 4 | 24 | 2 / 2 / 8 |
| staging | varnish | 2 | 12 | 2 / 2 / 6 |
| staging | frontend | 4 | 24 | 2 / 2 / 6 |
| production | varnish | 4 | 24 | 3 / 3 / 12 |
| production | frontend | 8 | 48 | 3 / 3 / 12 |

### Placement

Instance pools distribute instances across all configured availability domains. The `placement_configurations` block iterates `range(vcn.availability_domains_qty)` and assigns each AD its corresponding private subnet. OCI spreads instances as evenly as possible across those placements.

### Autoscaling

Each instance pool has one `oci_autoscaling_auto_scaling_configuration` with a `threshold` policy. Both pools share the same cooldown period. Scaling actions use `CHANGE_COUNT_BY` ±1 (one instance at a time).

| Environment | Scale-out threshold | Scale-in threshold | Cooldown |
|---|---|---|---|
| developer | CPU > 80% | CPU < 25% | 300 s |
| staging | CPU > 80% | CPU < 25% | 300 s |
| production | CPU > 75% | CPU < 20% | 300 s |

The `size` attribute on each pool is set to `desired_capacity` at creation and is excluded from `ignore_changes` tracking after that, so autoscaling adjustments are not reverted by subsequent `terraform apply` runs.

### Instance Configuration and Cloud-Init

`oci_core_instance_configuration` renders a per-pool `cloud-init/<pool>.yaml` template. Template variables passed at render time include the NFS mount target IP addresses (per AD), MySQL hostname, OpenSearch FQDN, Object Storage namespace, Vault OCID, and compartment OCID. Ansible Core runs inside cloud-init (no SSH or external control plane required). The instance's `create_vnic_details` sets `assign_public_ip = false` and attaches the compute NSG.

---

## Load Balancers

### Public Load Balancer (`load_balancer.tf`)

| Attribute | Value |
|---|---|
| Shape | Flexible, 10–100 Mbps |
| Visibility | Public (subnets: all public subnets) |
| NSG | `lb-nsg` |
| WAF | `oci_waf_web_app_firewall` attached |

**Listeners**

| Name | Port | Protocol | Backend set | Notes |
|---|---|---|---|---|
| `http-listener` | 80 | HTTP | `varnish-backend-set` | Applies HTTP→HTTPS redirect rule set when TLS enabled (301) |
| `https-listener` | 443 | HTTP2 | `varnish-backend-set` | TLSv1.2/TLSv1.3, cipher suite `oci-default-http2-tls-13-ssl-cipher-suite-v1` |
| `imgproxy-listener` | 8080 | HTTP | `frontend-backend-set` | Bypasses Varnish for image transformation traffic |

**Backend sets**

| Name | Policy | Health check |
|---|---|---|
| `varnish-backend-set` | ROUND_ROBIN | HTTP GET `/<health_check_token>` :80, expect 200, 10 s interval, 3 s timeout, 3 retries |
| `frontend-backend-set` | ROUND_ROBIN | HTTP GET `/health` :8080, expect 200, 10 s interval, 3 s timeout, 3 retries |

The health check path for the Varnish backend set uses the randomly generated `health_check` token (stored in Vault). This token is also exempted from rate-limiting in the WAF configuration.

### Private Internal Load Balancer (`internal_lb.tf`)

| Attribute | Value |
|---|---|
| Shape | Flexible, 10–100 Mbps |
| Visibility | Private (subnets: all private subnets) |
| NSG | `internal-lb-nsg` |
| WAF | Not attached (traffic originates inside VCN from Varnish) |

**Listeners**

| Name | Port | Protocol | Backend set | Idle timeout |
|---|---|---|---|---|
| `internal-frontend-listener` | 8080 | HTTP | `internal-frontend-backend-set` | 600 s |

**Backend set**

| Name | Policy | Health check |
|---|---|---|
| `internal-frontend-backend-set` | ROUND_ROBIN | HTTP GET `/health` :8080, expect 200, 10 s interval, 3 s timeout, 3 retries |

The frontend instance pool registers itself with both the public LB's `frontend-backend-set` (port 8080, for imgproxy) and the internal LB's `internal-frontend-backend-set` (port 8080, for Varnish pass-through).

---

## WAF

OCI WAF is attached to the public load balancer only. The WAF policy is evaluated in order: access control rules run before rate-limiting rules.

### Actions

| Name | HTTP response | Header |
|---|---|---|
| `GEO_BLOCK` | 403 | `X-WAF-Block: geo` |
| `RATE_LIMIT` | 429 | `Retry-After: 60` |
| `ADMIN_BLOCK` | 403 | `X-WAF-Block: admin` |

### Access control rules

**Geo-block** — blocks requests where `http.request.geolocation.country_code` matches any entry in `waf.restricted_countries`. Default configured countries: CN, RU, IR, KP, SD, SY, CU.

**Admin path IP restriction** — this rule is a `dynamic` block and is only created when `waf.admin_allowed_cidrs` is non-empty. When active, any request whose path begins with `/<admin_path_token>` and whose source IP is not in the allow list receives a 403. When `admin_allowed_cidrs` is empty (the default), the rule does not exist and the admin path is accessible from any IP (rate-limiting still applies).

### Rate-limiting rules

**Global rate limit** — applies to all requests except the LB health check path (`http.request.url.path != '/<health_check_token>'`). Default: 100 requests per 60 seconds per IP; block duration 60 seconds.

**Admin path rate limit** — applies to paths beginning with `/<admin_path_token>`. Default: 20 requests per 60 seconds; block duration 300 seconds.

---

## Database

MySQL HeatWave is provisioned as a single `oci_mysql_mysql_db_system` in private subnet AD-0. The instance uses a custom `oci_mysql_mysql_configuration` resource with the following non-default parameters:

| Parameter | Default value |
|---|---|
| `max_allowed_packet` | 268435456 (256 MiB) |
| `wait_timeout` | 7200 |
| `interactive_timeout` | 7200 |
| `innodb_lock_wait_timeout` | 60 |

`innodb_flush_log_at_trx_commit` is not exposed by the OCI Terraform provider's `variables` block and must be set via MySQL CLI after provisioning.

**High availability**: controlled by `is_highly_available = local.environment == "production"`. Developer and staging environments use a single-node (non-HA) system. Production enables the standby replica. Disabling HA on a running production cluster removes the standby — this is annotated with a warning comment in the resource.

**Backup policy**: automated daily backups are always enabled. Retention differs per environment:

| Environment | Retention |
|---|---|
| developer | 7 days |
| staging | 14 days |
| production | 30 days |

Backup window is fixed at 01:00 UTC.

---

## Cache

Two OCI Cache Redis clusters are provisioned per environment, one for PHP sessions and one for the Magento page/block cache. Both use OCI Cache software version `REDIS_7_0` and 4 GB node memory.

| Cluster | developer nodes | staging nodes | production nodes | developer subnet | staging subnet | production subnet |
|---|---|---|---|---|---|---|
| `session` | 1 | 1 | 3 | Private AD-0 | Private AD-0 | Private AD-0 |
| `cache` | 1 | 1 | 3 | Private AD-0 | Private AD-1 | Private AD-1 |

In developer, both clusters share private subnet AD-0. In staging and production, the cache cluster is placed in AD-1 to distribute load across availability domains.

Redis AUTH is not yet supported as a first-class attribute in the OCI provider at provider version `~> 6.0`. The generated Redis password is stored in the Vault as the `<project>-redis-password` secret and is applied to the cluster after initial creation.

---

## Search

OCI OpenSearch is provisioned in private subnet AD-0. Node counts vary by environment:

| Node type | developer | staging | production | OCPUs | Memory (GB) |
|---|---|---|---|---|---|
| Data | 1 | 2 | 3 | 1 | 16 |
| Master | 0 | 1 | 3 | 1 | 8 |
| Dashboard | 1 | 1 | 1 | 1 | 8 |

Per-data-node storage: 50 GB. Data and master nodes use `FLEX` host type.

**NSG rules** (defined in `security_groups.tf`):

- Port 9200 (REST API): ingress from `compute` NSG only.
- Port 9300 (cluster transport): ingress from `opensearch` NSG itself (self-referencing, inter-node communication).

The OpenSearch FQDN is passed into cloud-init as a template variable so Ansible can configure the Magento search endpoint without querying Terraform outputs at runtime.

---

## Shared File Storage

OCI File Storage (FSS) provides shared NFS mounts for the `var/` and `media/` directories that must be consistent across all frontend instances.

**Structure:**

- One `oci_file_storage_file_system` — regional, created in AD-0. All mount targets and exports reference the same file system.
- One `oci_file_storage_mount_target` per availability domain, placed in the corresponding private subnet and attached to the `nfs-nsg`.
- One `oci_file_storage_export_set` per mount target.
- Exports are created for each mount path (`/var`, `/media`) multiplied by each mount target.

**Export options**: each export restricts `source` to the private subnet CIDR of its own AD (`cidrsubnet(cidr, 4, mt_idx + 8)`), with `identity_squash = ROOT` and `access = READ_WRITE`. The NFS NSG still permits inbound port 2049 from the compute NSG across all ADs — this is an intentional defense-in-depth design: the NSG operates at the network layer and the export options operate at the NFS protocol layer. A compute instance in AD-1 can establish a TCP connection to the AD-0 mount target, but the NFS server will reject the mount because the source IP is not in the AD-0 subnet. Each AD's compute instances should mount from their local mount target to avoid cross-AD latency.

---

## Object Storage

Four OCI Object Storage buckets are provisioned for every environment:

| Bucket suffix | Purpose | IAM access |
|---|---|---|
| `media` | Magento media files (user-uploaded images, documents) | manage objects |
| `media-optimized` | Processed/resized media (imgproxy output) | read objects |
| `system` | Deployment artifacts, configuration packages | read objects |
| `backup` | Database and application backups | manage objects |

All buckets are created with `access_type = "NoPublicAccess"` and `versioning = "Enabled"`. Access is via the compute instance dynamic group IAM policy — no public URLs, no pre-authenticated requests by default.

---

## Secrets and IAM

### OCI Vault

An OCI Vault of type `DEFAULT` is provisioned with a 256-bit AES master key (`oci_kms_key.this`, `algorithm = "AES"`, `length = 32`). Both the vault and the master key have `prevent_destroy = true` in their lifecycle blocks.

All generated secrets are stored as `oci_vault_secret` resources using `BASE64` content encoding, encrypted with the project master key.

### Generated secrets

| Secret key | Terraform source | Purpose |
|---|---|---|
| `MYSQL_PASSWORD` | `random_password` (length 32, mixed case + numeric + special) | MySQL admin password |
| `REDIS_PASSWORD` | `random_password` | Redis AUTH token |
| `OPENSEARCH_PASSWORD` | `random_password` | OpenSearch admin password |
| `OPENSEARCH_ADMIN` | `random_string` (length 16, alphanumeric) | OpenSearch admin username suffix |
| `ADMIN_PATH` | `random_string` (length 16, alphanumeric) | Magento admin URL segment |
| `HEALTH_CHECK` | `random_string` (length 16, alphanumeric) | LB health check path token |
| `SECURITY_HEADER` | `random_uuid` | Internal security header value |

Secret names in Vault follow the pattern `<project>-<lowercase-key-with-hyphens>`, for example `easecloud-magento-mysql-password`.

### Dynamic group and IAM policy

`oci_identity_dynamic_group.compute` matches all instances in the project compartment that carry the `oracle-tags.CreatedBy = terraform` tag:

```
Any {all {instance.compartment.id = '<compartment_ocid>', tag.oracle-tags.CreatedBy.value = 'terraform'}}
```

The associated IAM policy (`oci_identity_policy.compute`) grants least-privilege access scoped to specific buckets:

| Verb | Resource | Scope |
|---|---|---|
| `read` | `secret-bundles` | Project compartment |
| `use` | `vaults` | Project compartment |
| `read` | `objects` | Buckets: `media-optimized`, `system` only |
| `manage` | `objects` | Buckets: `media`, `backup` only |
| `use` | `file-family` | Project compartment |
| `read` | `instance-family` | Project compartment |

---

## DNS

### Public zone (`dns.tf`)

An OCI DNS primary zone of scope `GLOBAL` is created for the configured domain. Two records are created:

| Record | Type | TTL | Value |
|---|---|---|---|
| `<domain>` (apex) | A | 300 | Public LB IP address |
| `www.<domain>` | CNAME | 300 | `<domain>.` |

### Private zone (`service_discovery.tf`)

A private DNS view and zone (`<brand>.internal`) are created for internal service discovery. All records have short TTLs to accommodate instance pool membership changes.

| Record | Type | TTL | Points to |
|---|---|---|---|
| `mysql.<brand>.internal` | CNAME | 60 | MySQL DB system endpoint hostname |
| `redis-session.<brand>.internal` | A | 60 | Redis session cluster primary endpoint IP |
| `redis-cache.<brand>.internal` | A | 60 | Redis cache cluster primary endpoint IP |
| `opensearch.<brand>.internal` | CNAME | 60 | OpenSearch cluster FQDN |
| `frontend.<brand>.internal` | A | 30 | Internal LB IP address |

Application configuration generated by Ansible uses these names rather than raw IP addresses or OCI-assigned hostnames.

---

## Security Model Summary

| Layer | Mechanism |
|---|---|
| Perimeter | OCI WAF — geo-block, rate-limit, admin-path IP restriction |
| Network ingress | NSGs per tier — LB, compute, internal LB, database, cache, NFS, OpenSearch |
| No public instance IPs | Private subnets enforce `prohibit_public_ip_on_vnic = true` |
| Outbound (private subnets) | NAT Gateway — egress only, no unsolicited inbound |
| Secret storage | OCI Vault (AES-256), secrets never written to Terraform state in plaintext |
| IAM | Dynamic group + least-privilege policy; no long-lived credentials on instances |
| Operator access | OCI Bastion service (STANDARD type) against private subnet AD-0; no SSH from internet |
| NFS export restriction | Per-AD CIDR source restriction at NFS protocol layer (defense-in-depth with NSG) |

---

## High Availability Matrix

| Component | developer | staging | production |
|---|---|---|---|
| Availability domains | 2 | 2 | 2 |
| Varnish pool (min instances) | 2 | 2 | 3 |
| Frontend pool (min instances) | 2 | 2 | 3 |
| MySQL | Single node | Single node | HA (primary + standby) |
| Redis session | 1 node | 1 node | 3 nodes |
| Redis cache | 1 node | 1 node | 3 nodes |
| OpenSearch data nodes | 1 | 2 | 3 |
| OpenSearch master nodes | 0 (data nodes act as master) | 1 | 3 |
| OpenSearch dashboard nodes | 1 | 1 | 1 |
| FSS file system | Single (regional) | Single (regional) | Single (regional) |
| FSS mount targets | 2 (one per AD) | 2 (one per AD) | 2 (one per AD) |
| Object storage | Managed by OCI (region-level) | Managed by OCI | Managed by OCI |
