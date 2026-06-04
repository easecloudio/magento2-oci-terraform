# Configuration Reference

This document is the authoritative reference for every configuration key in the Magento 2 OCI Terraform project. It covers the YAML config files, how Terraform reads them, and the four Terraform input variables that sit outside the YAML layer.

---

## Config file structure

Each environment maps to a single YAML file in the project root:

| Terraform workspace | Config file               |
|---------------------|---------------------------|
| `developer`         | `developer.config.yaml`   |
| `staging`           | `staging.config.yaml`     |
| `production`        | `production.config.yaml`  |

`locals.tf` loads all three files at plan time using `try(file(...), "")`, then selects the one matching the active workspace:

```hcl
locals {
  environment = lower(terraform.workspace)

  config_files = {
    developer  = try(file("${abspath(path.root)}/developer.config.yaml"), "")
    staging    = try(file("${abspath(path.root)}/staging.config.yaml"), "")
    production = try(file("${abspath(path.root)}/production.config.yaml"), "")
  }

  env = yamldecode(local.config_files[local.environment])
}
```

The decoded map is referenced everywhere as `local.env.<section>.<key>`. A workspace name that does not match one of the three keys will produce a key-lookup error at plan time.

Two derived locals are worth noting:

- `local.project` = `lower("${brand}-${codename}")`, e.g. `easecloud-magento`
- `local.db_name` = `local.project` with hyphens replaced by underscores

---

## Complete YAML reference

### Top-level identity keys

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `brand` | string | yes | Short brand slug. Combined with `codename` to form the project name used in every OCI resource display name and freeform tag. |
| `codename` | string | yes | Application codename. Combined with `brand` to form the project name. |
| `github_repo` | string | yes | Source repository in `org/repo` format. Used in cloud-init to check out the Ansible playbooks during instance boot. |
| `domain` | string | yes | Primary domain, e.g. `yourdomain.com`. Used for DNS records and TLS certificate subject. |
| `admin_email` | string | yes | Email address for budget alerts and operational notifications. |

Example (all environments share the same structure; only values differ):

```yaml
brand: easecloud
codename: magento
github_repo: "your-org/your-magento-repo"
domain: "yourdomain.com"
admin_email: "admin@yourdomain.com"
```

---

### `oci`

OCI provider authentication and targeting.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `oci.region` | string | yes | OCI region identifier, e.g. `us-ashburn-1`. Passed directly to the `oci` provider block. |
| `oci.tenancy_ocid` | string | yes | OCID of the tenancy root. Used as the target for the budget resource (budgets must be scoped to tenancy). |
| `oci.compartment_ocid` | string | yes | OCID of the compartment where all resources are created. Leave empty to inherit from environment variables or `~/.oci/config`. |

Authentication credentials are **not** placed in these files. Use `~/.oci/config` for local runs and `OCI_CLI_*` environment variables in CI.

---

### `vcn`

Virtual Cloud Network settings. Subnets are derived automatically from `cidr_block`.

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `vcn.cidr_block` | string | yes | `172.35.0.0/16` | CIDR block for the VCN. Public subnets are carved out of the lower half (`/20` each starting at offset 0); private subnets start at offset 8. |
| `vcn.availability_domains_qty` | int | yes | `2` | Number of availability domains to spread resources across. Controls how many public subnets, private subnets, mount targets, and pool placement configurations are created. Valid values: `1`, `2`, or `3`. |
| `vcn.dns_label` | string | yes | `vcn` | DNS label for the VCN. Must be 1–15 alphanumeric characters. Forms the base of the internal DNS zone `<dns_label>.oraclevcn.com`. |

Subnet allocation formula (from `locals.tf`):
- Public subnet `i`: `cidrsubnet(cidr_block, 4, i)` — offsets 0, 1, …
- Private subnet `i`: `cidrsubnet(cidr_block, 4, i + 8)` — offsets 8, 9, …

---

### `compute`

Instance pool configuration for the two compute tiers. The map key (`frontend`, `varnish`) determines which cloud-init template is used and which load balancer backend set each pool joins.

Both tiers use the same set of keys:

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `compute.<tier>.shape` | string | yes | OCI compute shape. `VM.Standard.A1.Flex` is the Ampere ARM64 Flex shape (free-tier eligible). |
| `compute.<tier>.ocpus` | int | yes | Number of OCPUs per instance. Flex shapes accept any integer value within OCI's shape limits. |
| `compute.<tier>.memory_gb` | int | yes | Memory per instance in GB. For A1.Flex the ratio must be between 1 GB and 64 GB per OCPU. |
| `compute.<tier>.volume_size_gb` | int | yes | Boot volume size in GB. Minimum 50 GB recommended for Magento. |
| `compute.<tier>.desired_capacity` | int | yes | Initial pool size. The autoscaler ignores this after the first apply (`ignore_changes = [size]`). |
| `compute.<tier>.min_size` | int | yes | Minimum instance count enforced by the autoscaler. |
| `compute.<tier>.max_size` | int | yes | Maximum instance count enforced by the autoscaler. |

Environment comparison:

| Key | Developer | Staging | Production |
|-----|-----------|---------|------------|
| `compute.frontend.ocpus` | 4 | 4 | 8 |
| `compute.frontend.memory_gb` | 24 | 24 | 48 |
| `compute.frontend.volume_size_gb` | 50 | 50 | 100 |
| `compute.frontend.desired_capacity` | 2 | 2 | 3 |
| `compute.frontend.min_size` | 2 | 2 | 3 |
| `compute.frontend.max_size` | 8 | 6 | 12 |
| `compute.varnish.ocpus` | 2 | 2 | 4 |
| `compute.varnish.memory_gb` | 12 | 12 | 24 |
| `compute.varnish.volume_size_gb` | 25 | 25 | 50 |
| `compute.varnish.desired_capacity` | 2 | 2 | 3 |
| `compute.varnish.min_size` | 2 | 2 | 3 |
| `compute.varnish.max_size` | 8 | 6 | 12 |

---

### `autoscaling`

CPU threshold-based autoscaling policy, applied identically to both the frontend and varnish pools.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `autoscaling.cooldown_in_seconds` | int | yes | Seconds to wait between successive scaling actions. OCI minimum is 300. |
| `autoscaling.out_threshold_percent` | int | yes | CPU utilization (%) above which a scale-out event adds one instance. |
| `autoscaling.in_threshold_percent` | int | yes | CPU utilization (%) below which a scale-in event removes one instance. |

Environment comparison:

| Key | Developer | Staging | Production |
|-----|-----------|---------|------------|
| `autoscaling.cooldown_in_seconds` | 300 | 300 | 300 |
| `autoscaling.out_threshold_percent` | 80 | 80 | 75 |
| `autoscaling.in_threshold_percent` | 25 | 25 | 20 |

Production uses tighter thresholds to scale out earlier and scale in later, protecting against traffic spikes.

---

### `mysql`

MySQL HeatWave DB System configuration.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `mysql.shape` | string | yes | MySQL HeatWave shape name. Determines CPU and RAM of the DB instance. |
| `mysql.storage_size_gb` | int | yes | Data storage size in GB. |
| `mysql.backup_retention_days` | int | yes | Number of days to retain automated backups. |
| `mysql.engine_version` | string | yes | MySQL major version. Currently only `"8.0"` is supported by OCI MySQL HeatWave. |
| `mysql.admin_username` | string | yes | Username for the MySQL admin account. The password is generated by Terraform and stored in OCI Vault. |
| `mysql.parameters` | list of objects | yes | List of MySQL system variable overrides. Each entry has `name` (string) and `value` (string). |

High-availability note: when the workspace is `production`, `is_highly_available = true` is set automatically in `database.tf`, adding a standby replica. This is hardcoded in Terraform, not a YAML key.

**`mysql.parameters` entries**

The following variables are applied via `oci_mysql_mysql_configuration`:

| Name | Default value | Notes |
|------|--------------|-------|
| `max_allowed_packet` | `268435456` | 256 MB; required for large Magento import payloads. |
| `wait_timeout` | `7200` | 2 hours; prevents idle connection drops during long batch jobs. |
| `interactive_timeout` | `7200` | 2 hours; same rationale as `wait_timeout`. |
| `innodb_lock_wait_timeout` | `60` | Seconds before a lock wait times out. |
| `innodb_flush_log_at_trx_commit` | `2` | Declared in YAML but **not applied by the OCI Terraform provider**. Set this manually via MySQL CLI after provisioning. |

Environment comparison:

| Key | Developer | Staging | Production |
|-----|-----------|---------|------------|
| `mysql.shape` | `MySQL.VM.Standard.E4.1.8GB` | `MySQL.VM.Standard.E4.1.16GB` | `MySQL.VM.Standard.E4.2.32GB` |
| `mysql.storage_size_gb` | 50 | 100 | 500 |
| `mysql.backup_retention_days` | 7 | 14 | 30 |

---

### `redis`

OCI Cache (Redis) cluster configuration. Multiple named clusters are supported; the typical setup has one cluster for sessions and one for application cache.

**Top-level redis keys**

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `redis.node_memory_in_gbs` | int | yes | Memory per node in GB. Applies to all clusters. |
| `redis.software_version` | string | yes | OCI Cache software version string. Valid values include `REDIS_7_0`. |
| `redis.clusters` | list of objects | yes | List of cluster definitions. |

**`redis.clusters[]` object**

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `redis.clusters[].name` | string | yes | Cluster identifier. Forms part of the OCI resource display name (`{project}-redis-{name}`). Also used as the Terraform `for_each` key. |
| `redis.clusters[].node_count` | int | yes | Number of nodes in this cluster. `1` = single node (no replication); `3` = a three-node cluster with replication. |
| `redis.clusters[].subnet_index` | int | yes | Index into the private subnet list (0-based). Use different indexes to spread clusters across availability domains. |

Environment comparison:

| Key | Developer | Staging | Production |
|-----|-----------|---------|------------|
| `redis.node_memory_in_gbs` | 4 | 4 | 4 |
| `redis.clusters[session].node_count` | 1 | 1 | 3 |
| `redis.clusters[session].subnet_index` | 0 | 0 | 0 |
| `redis.clusters[cache].node_count` | 1 | 1 | 3 |
| `redis.clusters[cache].subnet_index` | 0 | 1 | 1 |

In developer, both clusters share the same subnet. In staging and production, the session and cache clusters are placed in different subnets (different ADs).

---

### `opensearch`

OCI OpenSearch cluster configuration. Node sizing is fixed in `search.tf` (1 OCPU / 16 GB for data nodes; 1 OCPU / 8 GB for master and dashboard nodes). Only counts are configurable via YAML.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `opensearch.node_count` | int | yes | Number of data nodes. |
| `opensearch.master_node_count` | int | yes | Number of dedicated master nodes. Set to `0` for single-node or dev deployments where master election is not required. |
| `opensearch.opendashboard_node_count` | int | yes | Number of OpenSearch Dashboard nodes. Set to `0` to disable the dashboard. |
| `opensearch.software_version` | string | yes | OpenSearch version. Example: `"2.11.0"`. |

Environment comparison:

| Key | Developer | Staging | Production |
|-----|-----------|---------|------------|
| `opensearch.node_count` | 1 | 2 | 3 |
| `opensearch.master_node_count` | 0 | 1 | 3 |
| `opensearch.opendashboard_node_count` | 1 | 1 | 1 |

A `master_node_count` of 0 is acceptable for development; production should have 3 dedicated master nodes to avoid split-brain.

---

### `object_storage`

OCI Object Storage buckets to create. Each bucket is prefixed with `{project}-`.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `object_storage.buckets` | list of strings | yes | List of bucket name suffixes. All buckets are created with versioning enabled and no public access. |

Default buckets across all environments:

| Bucket suffix | Purpose |
|---------------|---------|
| `media` | Raw Magento media files |
| `media-optimized` | Resized / optimized image variants |
| `system` | Magento system exports and configuration dumps |
| `backup` | Database and application backups |

---

### `file_storage`

OCI File Storage (NFS) export configuration. One file system is created; exports and mount targets are replicated across all ADs as determined by `vcn.availability_domains_qty`.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `file_storage.mounts` | map of objects | yes | Map of NFS export definitions keyed by mount name. The key becomes the NFS export path (`/{key}`). |
| `file_storage.mounts.<name>.uid` | int | yes | UID that should own the mount point on the instance (applied via cloud-init / Ansible). |
| `file_storage.mounts.<name>.gid` | int | yes | GID that should own the mount point on the instance. |
| `file_storage.mounts.<name>.permissions` | string | yes | Octal permission string for the mount point directory, e.g. `"2770"` (setgid + owner rwx + group rwx). |

Default mounts (identical across all environments):

| Mount name | Export path | UID | GID | Permissions |
|------------|-------------|-----|-----|-------------|
| `var` | `/var` | 1001 | 1002 | `2770` |
| `media` | `/media` | 1001 | 1002 | `2770` |

NFS export options (hardcoded in `filesystem.tf`): `READ_WRITE` access, `ROOT` identity squash, no privileged source port required. Each mount target's export is restricted at the NFS protocol layer to the private subnet CIDR of its own AD.

---

### `waf`

OCI WAF policy configuration. The WAF is attached to the public load balancer.

#### `waf.restricted_countries`

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `waf.restricted_countries` | list of strings | yes | ISO 3166-1 alpha-2 country codes to block at the WAF. Requests from these countries receive a 403 response with `X-WAF-Block: geo`. |

Default blocked countries (all environments): `CN`, `RU`, `IR`, `KP`, `SD`, `SY`, `CU`.

#### `waf.rate_limit`

Applied to all requests except the health check path.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `waf.rate_limit.requests_limit` | int | yes | Maximum requests per source IP within `period_in_seconds`. |
| `waf.rate_limit.period_in_seconds` | int | yes | Time window in seconds for the rate limit count. |
| `waf.rate_limit.action_duration_in_seconds` | int | yes | How long the client remains blocked after exceeding the limit. A 429 response with `Retry-After` is returned. |

Default across all environments: 100 requests / 60 seconds / blocked for 60 seconds.

#### `waf.admin_rate_limit`

Applied only to requests whose path begins with the randomised admin path prefix.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `waf.admin_rate_limit.requests_limit` | int | yes | Maximum requests per source IP to the admin path within `period_in_seconds`. |
| `waf.admin_rate_limit.period_in_seconds` | int | yes | Time window in seconds. |
| `waf.admin_rate_limit.action_duration_in_seconds` | int | yes | Block duration in seconds after exceeding the admin rate limit. |

Default across all environments: 20 requests / 60 seconds / blocked for 300 seconds.

#### `waf.admin_allowed_cidrs`

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `waf.admin_allowed_cidrs` | list of strings | yes | CIDR blocks allowed to access the admin path. When the list is **non-empty**, a WAF access control rule is created that blocks all admin requests from IPs not in the list. When the list is **empty**, no IP restriction rule is created (admin path is accessible from any IP, subject to rate limiting only). |

Default across all environments: `[]` (no IP restriction).

**Production requirement:** Replace `[]` with your office or VPN CIDRs before going live. The production config file includes a comment to this effect.

---

### `password`

Controls which named passwords Terraform generates via `random_password`.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `password` | list of strings | yes | List of password identifiers. For each entry, a 32-character random password is generated and stored in OCI Vault as `{project}-{name}-password`. |

Default entries (identical across all environments):

| Entry | Vault secret name pattern | Used for |
|-------|--------------------------|----------|
| `database` | `{project}-database-password` | MySQL admin password |
| `redis` | `{project}-redis-password` | Redis AUTH token |
| `opensearch` | `{project}-opensearch-password` | OpenSearch basic auth |

Do not remove entries from this list after the initial apply. Doing so will destroy the corresponding Vault secret.

---

### `string`

Controls which named random strings Terraform generates via `random_string`.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `string` | list of strings | yes | List of string identifiers. For each entry, a 16-character alphanumeric string is generated and stored in OCI Vault. |

Default entries (identical across all environments):

| Entry | Vault secret name pattern | Used for |
|-------|--------------------------|----------|
| `admin_path` | `{project}-admin-path` | Randomised Magento admin URL prefix |
| `health_check` | `{project}-health-check` | Load balancer health check path; also excluded from WAF rate limiting |
| `opensearch_admin` | `{project}-opensearch-admin` | OpenSearch admin username |

---

### `budget`

OCI budget alert for the compartment.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `budget.amount` | int | yes | Monthly budget limit in USD. An alert is sent to `admin_email` when actual spend exceeds `threshold_percent` of this value. |
| `budget.threshold_percent` | int | yes | Percentage of `amount` at which the alert fires. Valid range: 1–100. |

Environment comparison:

| Key | Developer | Staging | Production |
|-----|-----------|---------|------------|
| `budget.amount` | 500 | 500 | 2000 |
| `budget.threshold_percent` | 90 | 85 | 80 |

Production uses a lower percentage threshold to give more lead time before the limit is reached.

---

## Terraform input variables

These variables are not part of the YAML config files. They are passed via `-var`, `terraform.tfvars`, or environment variables (`TF_VAR_<name>`).

### `ssh_public_key`

| Attribute | Value |
|-----------|-------|
| File | `variables.tf` |
| Type | `string` |
| Default | `""` (empty) |
| Sensitive | no |

SSH public key in OpenSSH format (`ssh-rsa AAAA…` or `ssh-ed25519 AAAA…`). When non-empty, the key is injected into the instance `metadata.ssh_authorized_keys` field of the instance configuration. When empty, no SSH key is installed and access is only possible via the OCI Bastion service (which does not require a pre-installed key for managed SSH sessions).

Set via environment variable for CI:
```sh
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
```

### `bastion_allowed_cidrs`

| Attribute | Value |
|-----------|-------|
| File | `variables.tf` |
| Type | `list(string)` |
| Default | `[]` (empty list) |
| Sensitive | no |

List of CIDR blocks allowed to create sessions on the OCI Bastion service. The Bastion is the only entry point to private instances when no public IP is assigned. An empty list means OCI applies no additional IP restriction beyond IAM policies.

Example:
```hcl
bastion_allowed_cidrs = ["203.0.113.0/24", "10.0.0.0/8"]
```

### `ssl_certificate_pem`

| Attribute | Value |
|-----------|-------|
| File | `tls.tf` |
| Type | `string` |
| Default | `""` (empty) |
| Sensitive | yes |

Full PEM-encoded certificate chain for the domain. When non-empty (alongside `ssl_private_key_pem`), an `oci_load_balancer_certificate` resource is created and the load balancer listener is configured for HTTPS with TLS termination. When empty, only an HTTP listener is created.

Supply via environment variable to avoid the value appearing in plan output or state in plain text:
```sh
export TF_VAR_ssl_certificate_pem="$(cat fullchain.pem)"
```

### `ssl_private_key_pem`

| Attribute | Value |
|-----------|-------|
| File | `tls.tf` |
| Type | `string` |
| Default | `""` (empty) |
| Sensitive | yes |

PEM-encoded private key matching the certificate in `ssl_certificate_pem`. Must be provided together with `ssl_certificate_pem`; providing one without the other will result in an incomplete TLS configuration.

```sh
export TF_VAR_ssl_private_key_pem="$(cat privkey.pem)"
```

---

## Environment comparison table

| Setting | Developer | Staging | Production |
|---------|-----------|---------|------------|
| Frontend shape | `VM.Standard.A1.Flex` | `VM.Standard.A1.Flex` | `VM.Standard.A1.Flex` |
| Frontend OCPUs | 4 | 4 | 8 |
| Frontend memory (GB) | 24 | 24 | 48 |
| Frontend desired / min / max | 2 / 2 / 8 | 2 / 2 / 6 | 3 / 3 / 12 |
| Varnish OCPUs | 2 | 2 | 4 |
| Varnish memory (GB) | 12 | 12 | 24 |
| Varnish desired / min / max | 2 / 2 / 8 | 2 / 2 / 6 | 3 / 3 / 12 |
| Autoscaling scale-out CPU % | 80 | 80 | 75 |
| Autoscaling scale-in CPU % | 25 | 25 | 20 |
| MySQL shape | `E4.1.8GB` | `E4.1.16GB` | `E4.2.32GB` |
| MySQL storage (GB) | 50 | 100 | 500 |
| MySQL backup retention (days) | 7 | 14 | 30 |
| MySQL high availability | no | no | yes (auto) |
| Redis node memory (GB) | 4 | 4 | 4 |
| Redis session node count | 1 | 1 | 3 |
| Redis cache node count | 1 | 1 | 3 |
| OpenSearch data nodes | 1 | 2 | 3 |
| OpenSearch master nodes | 0 | 1 | 3 |
| OpenSearch dashboard nodes | 1 | 1 | 1 |
| Budget amount (USD/month) | 500 | 500 | 2000 |
| Budget alert threshold | 90% | 85% | 80% |

---

## Adding a new environment

Follow these steps to create an environment such as `qa` or `performance`.

**1. Copy an existing config file as a starting point.**

```sh
cp developer.config.yaml qa.config.yaml
```

**2. Edit `qa.config.yaml`.**

At minimum update:
- `oci.tenancy_ocid` and `oci.compartment_ocid` — use the OCID for the target compartment.
- `domain` and `admin_email`.
- Compute sizes, MySQL shape, Redis node counts, and budget to match expected load.

**3. Register the new workspace name in `locals.tf`.**

Add an entry to `config_files`:

```hcl
config_files = {
  developer   = try(file("${abspath(path.root)}/developer.config.yaml"), "")
  staging     = try(file("${abspath(path.root)}/staging.config.yaml"), "")
  production  = try(file("${abspath(path.root)}/production.config.yaml"), "")
  qa          = try(file("${abspath(path.root)}/qa.config.yaml"), "")   # add this line
}
```

**4. Create the Terraform workspace.**

```sh
terraform workspace new qa
```

**5. Plan and review.**

```sh
terraform plan -out qa.plan
```

Review the plan carefully. A new environment creates all resources from scratch: VCN, subnets, instance pools, MySQL, Redis, OpenSearch, Object Storage buckets, File Storage, WAF, Vault, and budget.

**6. Apply.**

```sh
terraform apply qa.plan
```

**7. Set TLS variables for the new environment (if needed).**

```sh
export TF_VAR_ssl_certificate_pem="$(cat qa-fullchain.pem)"
export TF_VAR_ssl_private_key_pem="$(cat qa-privkey.pem)"
terraform apply qa.plan
```

To switch back to an existing environment at any time:

```sh
terraform workspace select developer
```
