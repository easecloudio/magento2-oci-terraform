# Magento 2 OCI Terraform

Deploy a production-ready, auto-scaling Magento 2 infrastructure on Oracle Cloud Infrastructure using Terraform and Ampere A1 instances.

## Overview

This project provisions a complete Magento 2 infrastructure on OCI including:

- **Instance Pools** — frontend (PHP-FPM + Nginx) and varnish tiers on Ampere A1 Flex ARM instances
- **MySQL HeatWave** — managed relational database with auto-backup and configurable parameters
- **OCI Cache (Redis)** — session and full-page cache clusters
- **OCI OpenSearch** — Magento catalog search
- **OCI Load Balancer** — with OCI WAF, SSL termination, and geo-blocking
- **Object Storage** — media, optimized media, system files, and backups
- **File Storage (NFS)** — shared `var/` and `media/` mounts across all instances
- **OCI Events + Notifications** — release deployment triggered by Object Storage uploads
- **Private DNS** — internal service discovery via OCI DNS private views

All configuration is driven by a single YAML file per environment (`developer.config.yaml`, `staging.config.yaml`, `production.config.yaml`). No `.tfvars` files needed.

## Architecture

```
Internet
   │
   ▼
OCI WAF
   │
   ▼
OCI Load Balancer
   │
   ├──▶ Varnish Instance Pool (cache layer)
   │         │
   └──▶ Frontend Instance Pool (Nginx + PHP-FPM)
              │
              ├──▶ MySQL HeatWave
              ├──▶ OCI Cache Redis (session + cache)
              ├──▶ OCI OpenSearch
              ├──▶ File Storage NFS (var/ + media/)
              └──▶ Object Storage (media + system)
```

## Prerequisites

- Terraform >= 1.9
- OCI CLI installed and configured (`oci setup config`)
- An OCI account with sufficient IAM policies to create all resources above
- Ampere A1 instance capacity available in your target region

### OCI Authentication

**Local development** — create `~/.oci/config` with your credentials:

```ini
[DEFAULT]
user=ocid1.user.oc1..example
fingerprint=xx:xx:xx:xx
tenancy=ocid1.tenancy.oc1..example
region=us-ashburn-1
key_file=~/.oci/oci_api_key.pem
```

Generate an API key pair in the OCI Console under **Profile → API Keys**, paste the public key there, and save the private key to `~/.oci/oci_api_key.pem`.

**CI/CD** — set the following environment variables (no config file needed):

| Variable | Description |
|---|---|
| `OCI_CLI_USER` | User OCID |
| `OCI_CLI_TENANCY` | Tenancy OCID |
| `OCI_CLI_FINGERPRINT` | API key fingerprint |
| `OCI_CLI_KEY_CONTENT` | PEM private key (raw content) |
| `OCI_CLI_REGION` | OCI region (e.g. `us-ashburn-1`) |

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/easecloud/magento2-oci-terraform.git
cd magento2-oci-terraform

# 2. Copy and edit your environment config
cp developer.config.yaml developer.config.yaml
# Edit developer.config.yaml: set brand, domain, admin_email, oci.tenancy_ocid, oci.compartment_ocid, etc.

# 3. Initialize Terraform
terraform init

# 4. Create a workspace matching your config file name
terraform workspace new developer

# 5. Plan and apply
terraform plan -out developer.plan
terraform apply developer.plan
```

## Configuration Reference

All environment settings live in `<workspace>.config.yaml`. Copy `developer.config.yaml` as a starting point:

| Key | Description |
|-----|-------------|
| `brand` | Short brand identifier — used in all resource names |
| `codename` | Project codename — combined with brand as `brand-codename` |
| `github_repo` | Source repository reference (used in tags and automation) |
| `domain` | Primary domain name for DNS and SSL |
| `admin_email` | Email for budget alerts and notifications |
| `oci.region` | OCI region identifier (e.g. `us-ashburn-1`) |
| `oci.tenancy_ocid` | OCID of your OCI tenancy |
| `oci.compartment_ocid` | OCID of the target compartment |
| `vcn.cidr_block` | VCN IP range (e.g. `172.35.0.0/16`) |
| `vcn.availability_domains_qty` | Number of availability domains to use |
| `vcn.dns_label` | DNS label for the VCN |
| `compute.frontend.shape` | OCI shape for frontend instances (e.g. `VM.Standard.A1.Flex`) |
| `compute.frontend.ocpus` | vCPU count for each frontend instance |
| `compute.frontend.memory_gb` | Memory in GB for each frontend instance |
| `compute.frontend.volume_size_gb` | Boot volume size in GB |
| `compute.frontend.desired_capacity` | Target number of frontend instances |
| `compute.frontend.min_size` | Minimum instances in the pool |
| `compute.frontend.max_size` | Maximum instances in the pool |
| `compute.varnish.shape` | OCI shape for varnish instances |
| `compute.varnish.ocpus` | vCPU count for each varnish instance |
| `compute.varnish.memory_gb` | Memory in GB for each varnish instance |
| `compute.varnish.volume_size_gb` | Boot volume size in GB |
| `compute.varnish.desired_capacity` | Target number of varnish instances |
| `compute.varnish.min_size` | Minimum instances in the pool |
| `compute.varnish.max_size` | Maximum instances in the pool |
| `autoscaling.cooldown_in_seconds` | Seconds to wait between scaling actions |
| `autoscaling.out_threshold_percent` | CPU % that triggers scale-out |
| `autoscaling.in_threshold_percent` | CPU % that triggers scale-in |
| `mysql.shape` | MySQL HeatWave shape (e.g. `MySQL.VM.Standard.E4.1.8GB`) |
| `mysql.storage_size_gb` | Initial data storage in GB |
| `mysql.backup_retention_days` | Number of days to retain automated backups |
| `mysql.engine_version` | MySQL engine version (e.g. `8.0`) |
| `mysql.admin_username` | Database administrator username |
| `mysql.parameters` | List of `{name, value}` MySQL server parameter overrides |
| `redis.node_count` | Number of nodes per Redis cluster |
| `redis.node_memory_in_gbs` | Memory per Redis node in GB |
| `redis.software_version` | Redis software version (e.g. `REDIS_7_0`) |
| `redis.name` | List of cluster names to create (e.g. `session`, `cache`) |
| `opensearch.node_count` | Number of data nodes |
| `opensearch.master_node_count` | Number of dedicated master nodes (0 = use data nodes) |
| `opensearch.opendashboard_node_count` | Number of OpenSearch Dashboard nodes |
| `opensearch.software_version` | OpenSearch version (e.g. `2.11.0`) |
| `object_storage.buckets` | List of bucket names to create (media, media-optimized, system, backup) |
| `file_storage.mounts.var.uid` | UID for `var/` NFS mount ownership |
| `file_storage.mounts.var.gid` | GID for `var/` NFS mount ownership |
| `file_storage.mounts.var.permissions` | Octal permissions for `var/` mount |
| `file_storage.mounts.media.uid` | UID for `media/` NFS mount ownership |
| `file_storage.mounts.media.gid` | GID for `media/` NFS mount ownership |
| `file_storage.mounts.media.permissions` | Octal permissions for `media/` mount |
| `waf.restricted_countries` | List of ISO 3166-1 alpha-2 country codes to block at WAF |
| `password` | List of secret names to generate and store as passwords |
| `string` | List of secret names to store as plain strings |
| `budget.amount` | Monthly budget limit in USD |
| `budget.threshold_percent` | Alert threshold as a percentage of the budget |

## Workspaces

Terraform workspaces map directly to config files:

| Workspace | Config file |
|-----------|-------------|
| `developer` | `developer.config.yaml` |
| `staging` | `staging.config.yaml` |
| `production` | `production.config.yaml` |

Switch workspaces with `terraform workspace select <name>`.

## No-SSH Access

Instances are not exposed via SSH. All management is handled through OCI-native mechanisms:

**OCI Bastion** — use the Bastion service to create a session that tunnels to the instance's private IP over port 22 without opening any security rules:

```bash
oci bastion session create-managed-ssh \
  --bastion-id <bastion-ocid> \
  --target-resource-id <instance-ocid> \
  --target-os-username opc \
  --ssh-public-key-file ~/.ssh/id_rsa.pub
```

**Oracle Cloud Agent — Run Command** — execute commands on instances directly from the console or CLI without a network path:

```bash
oci instance-agent command create \
  --compartment-id <compartment-ocid> \
  --execution-time-out-in-seconds 600 \
  --target '{"instanceId": "<instance-ocid>"}' \
  --content '{"source": {"sourceType": "TEXT", "text": "systemctl status nginx"}}'
```

Both methods require the Oracle Cloud Agent to be running on the instance and the appropriate IAM policy to be in place.

## Release Deployment

Releases are deployed by uploading a versioned zip archive to the `system` Object Storage bucket under a `release/` prefix. An OCI Events rule watches for `createobject` events on that bucket and publishes a notification to an ONS topic, which triggers the instance bootstrap process. Instances receive the notification via a subscription, download the release artifact, and run the deployment playbook using Oracle Cloud Agent.

## Security

- Credentials generated as random secrets and stored in OCI Vault
- No SSH access — all management via OCI Bastion or Oracle Cloud Agent Run Command
- WAF rules: geo-blocking, rate limiting, and OWASP managed rules
- Network security groups scoped per service tier
- Object Storage buckets are private with pre-authenticated requests for media delivery

## License

Apache 2.0 — see [LICENSE](LICENSE)
