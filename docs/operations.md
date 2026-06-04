# Operations Guide

Day-2 operations reference for a running Magento 2 OCI Terraform environment.

---

## Viewing infrastructure state

```bash
# Show all outputs for the current workspace
terraform workspace select production
terraform output

# Individual values
terraform output load_balancer_ip
terraform output mysql_endpoint
terraform output redis_endpoints
terraform output opensearch_endpoint
terraform output nfs_mount_target_ip
terraform output internal_lb_ip
terraform output bastion_private_ip
```

**OCI Console navigation**

| What to find | Console path |
|---|---|
| Instance Pools | Compute → Instance Pools → filter by project tag |
| Autoscaling configs | Compute → Autoscaling Configurations |
| Load Balancers | Networking → Load Balancers |
| WAF policy | Identity & Security → WAF → Policies |
| MySQL DB System | Databases → MySQL HeatWave |
| Redis clusters | Databases → OCI Cache with Redis |
| OpenSearch | Databases → OpenSearch |
| File Storage | Storage → File Storage → File Systems |
| Object Storage | Storage → Buckets |
| Vault & secrets | Security → Vaults |
| Bastion | Identity & Security → Bastion |
| Alarms | Observability & Management → Monitoring → Alarm Definitions |

All resources are tagged with `terraform=true`, `brand=<brand>`, `environment=<environment>`, and `project=<project>`. Use the tag filter in the Console search or in the resource list views to find resources belonging to a specific workspace.

---

## Instance access

Instances run in private subnets with no public IP address. Two access methods are available.

### OCI Bastion (recommended for interactive sessions)

Your source IP must be listed in `var.bastion_allowed_cidrs`. If it is not, add your CIDR to the variable and re-apply before attempting a session.

```bash
# 1. Get the bastion OCID from the Console or from state
BASTION_OCID=$(terraform output -raw bastion_private_ip)
# Note: bastion_private_ip output returns the private endpoint IP, not the OCID.
# Retrieve the OCID from: Identity & Security → Bastion → {project}-bastion → OCID field.

# 2. Get the target instance OCID
# Compute → Instance Pools → {project}-frontend-pool or {project}-varnish-pool → Instances

# 3. Create a managed SSH session
oci bastion session create-managed-ssh \
  --bastion-id <bastion-ocid> \
  --target-resource-id <instance-ocid> \
  --target-os-username opc \
  --ssh-public-key-file ~/.ssh/id_rsa.pub \
  --session-ttl-in-seconds 3600

# 4. Poll until the session state is ACTIVE
oci bastion session get --session-id <session-ocid> --query 'data."lifecycle-state"'

# 5. Connect using the SSH command shown in the session details
ssh -i ~/.ssh/id_rsa \
  -o StrictHostKeyChecking=no \
  -o ProxyCommand='ssh -W %h:%p -p 22 <session-ocid>@host.bastion.<region>.oci.oraclecloud.com' \
  opc@<instance-private-ip>
```

The SSH command is also shown in the OCI Console under the session detail page.

### Oracle Cloud Agent — Run Command (no network path required)

Run Command executes scripts on instances through the Oracle Cloud Agent, bypassing all network requirements. Useful for log inspection and one-off commands when Bastion is not configured.

```bash
# Read the last 100 lines of the cloud-init log
oci instance-agent command create \
  --compartment-id <compartment-ocid> \
  --execution-time-out-in-seconds 600 \
  --target '{"instanceId": "<instance-ocid>"}' \
  --content '{"source": {"sourceType": "TEXT", "text": "journalctl -u cloud-init --no-pager -n 100"}}'

# Get the command OCID from the response, then retrieve output
oci instance-agent command-execution get \
  --instance-agent-command-id <command-ocid> \
  --instance-id <instance-ocid>
```

### Cloud-init logs

Cloud-init progress is written to `/var/log/cloud-init-custom.log` on each instance. This log captures OCI CLI downloads, Ansible playbook output, and any errors during bootstrapping.

```bash
# Via Run Command
oci instance-agent command create \
  --compartment-id <compartment-ocid> \
  --execution-time-out-in-seconds 120 \
  --target '{"instanceId": "<instance-ocid>"}' \
  --content '{"source": {"sourceType": "TEXT", "text": "tail -n 200 /var/log/cloud-init-custom.log"}}'

# Via Bastion session
tail -f /var/log/cloud-init-custom.log
journalctl -u cloud-init --no-pager -n 200
```

The standard cloud-init status can be checked with:

```bash
cloud-init status --long
```

---

## Scaling

### How autoscaling works

Both the Varnish pool (`{project}-varnish-asc`) and the Frontend pool (`{project}-frontend-asc`) run threshold-based autoscaling policies:

| Direction | Metric | Threshold | Action |
|---|---|---|---|
| Scale out | CPU utilization | > `out_threshold_percent` (default 80%) | +1 instance |
| Scale in | CPU utilization | < `in_threshold_percent` (default 25%) | -1 instance |

The cooldown period between scaling events is `autoscaling.cooldown_in_seconds` (default 300 seconds). Min and max bounds come from `compute.frontend.min_size` / `max_size` and `compute.varnish.min_size` / `max_size` in the config YAML.

### Changing autoscaling thresholds

Edit the relevant values in your `<environment>.config.yaml`:

```yaml
autoscaling:
  cooldown_in_seconds: 300
  out_threshold_percent: 75   # scale out earlier
  in_threshold_percent: 20
```

Then apply:

```bash
terraform plan -out <environment>.plan
terraform apply <environment>.plan
```

### Manually resizing a pool

Change `desired_capacity` in the config YAML and re-apply:

```yaml
compute:
  frontend:
    desired_capacity: 4   # was 2
```

The instance pool `size` attribute has `ignore_changes = [size]` in the lifecycle block. This means Terraform will not override pool sizes that the autoscaler has changed. Setting `desired_capacity` in the YAML and re-applying only takes effect if the autoscaler has not already moved the pool away from the initial size; to force a specific size, also update `min_size` temporarily.

---

## Database operations

### Checking backup status

```bash
# List automated backups for the DB system
oci mysql backup list \
  --compartment-id <compartment-ocid> \
  --db-system-id <mysql-db-system-ocid> \
  --query 'data[*].{id:id, type:"backup-type", state:"lifecycle-state", created:"time-created"}' \
  --output table
```

The automated backup window is `01:00` UTC with retention set by `mysql.backup_retention_days` in the config (default 7 days).

### Creating a manual backup

```bash
oci mysql backup create \
  --db-system-id <mysql-db-system-ocid> \
  --display-name "manual-$(date +%Y%m%d-%H%M)" \
  --backup-type FULL \
  --retention-in-days 30
```

### Point-in-time restore

OCI MySQL point-in-time restore creates a new DB system from a backup:

```bash
oci mysql db-system create \
  --compartment-id <compartment-ocid> \
  --shape-name MySQL.VM.Standard.E4.1.8GB \
  --subnet-id <private-subnet-ocid> \
  --availability-domain <ad-name> \
  --admin-username magentoadmin \
  --admin-password <password> \
  --source '{"sourceType": "BACKUP", "backupId": "<backup-ocid>"}' \
  --display-name "{project}-mysql-restored"
```

After the restored system is available, update `mysql_endpoint` references in Magento configuration to point to the new hostname, then decommission the old system.

### MySQL parameter changes

MySQL parameters are managed through `oci_mysql_mysql_configuration.this`. To change a parameter, update the value in your `<environment>.config.yaml` under `mysql.parameters` and re-apply. The configuration resource uses `create_before_destroy`, so Terraform creates a new configuration then reassigns it to the DB system. The DB system must be restarted for most parameter changes to take effect:

```bash
oci mysql db-system restart \
  --db-system-id <mysql-db-system-ocid>
```

Note: `innodb_flush_log_at_trx_commit` is not exposed by the OCI provider's `variables` block. Set it directly via a MySQL client connection after provisioning.

---

## Redis operations

### Checking cluster health

```bash
# List Redis clusters
oci redis redis-cluster list \
  --compartment-id <compartment-ocid> \
  --query 'data[*].{name:"display-name", state:"lifecycle-state", nodes:"node-count", memory:"node-memory-in-gbs"}' \
  --output table

# Get detailed status for a specific cluster
oci redis redis-cluster get \
  --redis-cluster-id <cluster-ocid>
```

The session cluster is named `{project}-redis-session` and the page-cache cluster is `{project}-redis-cache`. Primary endpoint IPs are available via `terraform output redis_endpoints`.

### Redis password limitation

The `oci_redis_redis_cluster` resource in OCI provider v6.x does not expose the `auth_token` attribute. Redis AUTH is managed separately via `oci_redis_oci_cache_user` resources available in newer provider versions. The generated Redis password is stored in the OCI Vault secret named `{project}-redis-password` and must be applied to the cluster through an out-of-band step after cluster creation (OCI Console → Databases → OCI Cache with Redis → cluster → Manage Users, or via OCI CLI when the resource becomes available in the provider).

### Rotating Redis passwords

The Redis password is a `random_password` resource stored in Vault. To rotate it:

1. Taint the random password resource to force regeneration:
   ```bash
   terraform taint 'random_password.this["redis"]'
   ```
2. Apply. Terraform regenerates the password, updates the Vault secret, and on the next instance boot the new password is fetched by the Ansible playbook.
3. Update the Redis cluster's auth token through the OCI Console or CLI as described above.
4. Update `app/etc/env.php` on running frontend instances with the new password (or redeploy to trigger a cloud-init re-run).

---

## Monitoring alarms

Eight alarms are configured. All fire to the ONS topic `{project}-notifications` which emails `admin_email`. Alarm resource names follow the pattern `{project}-<alarm-name>`.

| Alarm display name | Metric | Threshold | Pending duration | Severity |
|---|---|---|---|---|
| `{project}-cpu-high` | `CpuUtilization[5m].mean()` | > 85% | 5 minutes | WARNING |
| `{project}-memory-high` | `MemoryUtilization[5m].mean()` | > 90% | 5 minutes | WARNING |
| `{project}-lb-5xx` | `Http5xxResponses[5m].sum()` | > 50 | 2 minutes | CRITICAL |
| `{project}-lb-unhealthy-backends` | `UnHealthyBackendServers[5m].max()` | > 0 | 2 minutes | CRITICAL |
| `{project}-mysql-connections-high` | `CurrentConnections[5m].max()` | > 80 | 5 minutes | WARNING |
| `{project}-mysql-storage-low` | `FreeDataStorageSpace[5m].min()` | < 10 GB | 2 minutes | CRITICAL |
| `{project}-redis-session-memory-high` | `UsedMemoryPercentage[5m].mean()` | > 80% | 5 minutes | WARNING |
| `{project}-redis-cache-memory-high` | `UsedMemoryPercentage[5m].mean()` | > 80% | 5 minutes | WARNING |
| `{project}-opensearch-cluster-unhealthy` | `ClusterStatus[5m].max()` | > 0 | 2 minutes | CRITICAL |

The Redis alarms are created with `for_each` over `oci_redis_redis_cluster.this`, so one alarm exists per configured cluster.

### Silencing an alarm

Suppress an alarm for a maintenance window in the OCI Console: Observability & Management → Monitoring → Alarm Definitions → select the alarm → Suppress Alarms. Or via CLI:

```bash
oci monitoring alarm suppress \
  --alarm-id <alarm-ocid> \
  --time-suppress-from "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --time-suppress-until "$(date -u -v+2H +%Y-%m-%dT%H:%M:%SZ)" \
  --description "Planned maintenance"
```

### Adding alarms

Add a new `oci_monitoring_alarm` resource to `monitoring.tf` following the same pattern as the existing alarms. Set `destinations = [oci_ons_notification_topic.default.id]` to route to the same email topic, or create a second ONS topic for a different notification endpoint (PagerDuty, Slack webhook, etc.).

---

## Log access

Cloud-init and Ansible provisioning logs are at `/var/log/cloud-init-custom.log` on each instance. Access them via Run Command (no network path needed) or via a Bastion session.

No centralized log aggregation is configured. Logs exist only on individual instances and are lost when an instance is terminated (for example during a scale-in event or an instance pool update). OCI Logging service integration with a log group and agent configuration is a planned enhancement.

To retain important provisioning output before an instance is replaced, copy the log to Object Storage:

```bash
# Run on the instance via Bastion or Run Command
oci os object put \
  --bucket-name ${PROJECT}-system \
  --name "logs/$(hostname)-cloud-init-$(date +%Y%m%d%H%M%S).log" \
  --file /var/log/cloud-init-custom.log \
  --auth instance_principal
```

---

## Certificate renewal

When your TLS certificate is due for renewal (Let's Encrypt: 90-day cycle; commercial CAs: 1–2 year cycle):

```bash
# Set the updated certificate content
export TF_VAR_ssl_certificate_pem="$(cat new-fullchain.pem)"
export TF_VAR_ssl_private_key_pem="$(cat new-privkey.pem)"

terraform workspace select <environment>
terraform plan -out <environment>.plan
terraform apply <environment>.plan
```

The certificate resource is `oci_load_balancer_certificate.this` with the stable name `{project}-cert`. Terraform updates the certificate in-place on the load balancer with no IP change and no listener downtime. The load balancer performs a rolling update to replace the certificate on active connections.

If you automate renewal with Certbot or acme.sh, pipe the renewed files into the `TF_VAR_*` variables and trigger a `terraform apply` as part of the renewal hook.

---

## Upgrading the Terraform provider

The provider version constraint in `provider.tf` is `~> 6.0` (any 6.x version). To upgrade to a new minor version:

```bash
terraform init -upgrade
```

This updates `.terraform.lock.hcl` with the new provider hash. Review the OCI provider changelog for breaking changes before upgrading. Commit the updated lock file:

```bash
git add .terraform.lock.hcl
git commit -m "chore: upgrade OCI provider to $(terraform providers | grep oracle/oci | head -1)"
```

To pin to a specific version, update `provider.tf`:

```hcl
oci = {
  source  = "oracle/oci"
  version = "6.37.0"   # pin explicitly
}
```

After updating the constraint, run `terraform init -upgrade` again and commit the new lock file.

When upgrading from provider 6.x to 7.x, expect breaking changes to Redis (`oci_redis_redis_cluster`) and possibly WAF resources. Test the upgrade in the `developer` workspace before applying to `production`.
