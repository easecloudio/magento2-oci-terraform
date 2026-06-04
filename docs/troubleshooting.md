# Troubleshooting

Symptom-first reference for common issues when deploying and operating this infrastructure.

---

## Instance pools not receiving traffic (502 from Load Balancer)

**Symptom:** The load balancer returns `502 Bad Gateway` immediately after `terraform apply` completes.

**Cause:** OCI instance pools take several minutes to launch, run cloud-init, and pass health checks. Until at least one backend registers as `OK`, the backend set has no healthy targets and the LB returns 502 for all requests.

The health check configuration:
- Varnish backend set: HTTP GET `/${health_check_token}` on port 80, 200 expected, 10-second interval, 3 retries
- Frontend backend set: HTTP GET `/health` on port 8080, 200 expected, 10-second interval, 3 retries

**Resolution:**
1. In the OCI Console, go to **Networking > Load Balancers > `${project}-lb` > Backend Sets**.
2. Open each backend set and check the **Backend status** column.
3. If backends show `UNKNOWN` or `CRITICAL`, cloud-init is still running or has not yet started the application processes.
4. Wait 5–10 minutes and refresh. A fresh instance boot with `package_upgrade: true` can take 8–12 minutes on a slow mirror.
5. If backends never become `OK`, see the cloud-init section below.

---

## cloud-init fails silently

**Symptom:** Instances are running but the application is not responding. Backends remain unhealthy. No visible error in the OCI Console.

**Reading cloud-init logs:**

The preferred method when `var.ssh_public_key` is set and a Bastion session is active:

```bash
journalctl -u cloud-init --no-pager
journalctl -u cloud-init-local --no-pager
cat /var/log/cloud-init-output.log
```

If SSH is not available, use **OCI Run Command** (OCI Console > Compute > Instances > select instance > Run Command).

**Common causes:**

| Symptom in logs | Cause | Fix |
|---|---|---|
| `ansible-playbook: command not found` | OCI CLI installs Ansible via pipx but the PATH is not exported before subsequent steps run | Verify cloud-init `runcmd` exports `~/.local/bin` to PATH before calling `ansible-playbook`. The cloud-init template appends `export PATH=$HOME/.local/bin:$PATH` after the pipx install step. |
| `Failed to connect to vault.region.oraclevcn.com` | Instance cannot reach OCI Vault endpoint | Check that the NAT Gateway is healthy and the private route table has a `0.0.0.0/0 → NGW` rule. |
| `Secret not found: ${project}-mysql-password` | Secret name mismatch or Vault not yet reachable | See the Vault secret not found section below. |
| Ansible collection install fails | PyPI or Ansible Galaxy unreachable via NAT | Check NAT Gateway; try `curl -I https://pypi.org` from the instance via Run Command. |

---

## NFS mount fails

**Symptom:** Application logs show file permission errors or missing directories. `mount` output on the instance does not include the OCI File Storage mount target.

**Checklist:**

1. **nfs-common installed.** The cloud-init playbook installs `nfs-common` on Ubuntu/Debian. Verify with `dpkg -l nfs-common` via Run Command.

2. **NFSv4 required.** OCI File Storage only exposes port 2049 (NFSv4). The mount command must specify `nfsvers=4` or `vers=4`. NFS v3 ports (111, 2048) are not open.

3. **NSG rule in place.** Confirm that the compute instance's VNIC is attached to `compute-nsg` and that the File Storage mount target is attached to `nfs-nsg`. The rule `compute-nsg → nfs-nsg TCP 2049` must exist in `security_groups.tf` and be active.

4. **Export options CIDR.** OCI File Storage export options restrict which client IPs can mount. The Terraform configuration sets the allowed CIDR to the private subnet CIDR. If an instance's IP is outside that range (for example, after a subnet CIDR change), the mount will be denied at the NFS layer with a `permission denied` error rather than a connection error.

   To verify: OCI Console > Storage > File Storage > File Systems > select filesystem > Exports > View Export Options.

---

## Vault secret not found

**Symptom:** cloud-init or Ansible exits with an error similar to `HTTP 404` or `No secret found with name ${project}-mysql-password` when calling `oci secrets secret-bundle get-secret-bundle-by-name`.

**Checklist:**

1. **Dynamic group membership.** The dynamic group matching rule requires two conditions:
   - `instance.compartment.id = '<compartment_ocid>'`
   - `tag.oracle-tags.CreatedBy.value = 'terraform'`

   Both must be true. Verify the instance carries the `oracle-tags.CreatedBy = terraform` tag in the OCI Console under the instance's **Tags** tab. If the tag is missing, the instance is not a member of the dynamic group and all `read secret-bundles` calls will return 401/403.

2. **IAM policy propagation delay.** OCI IAM policy changes can take 60–90 seconds to propagate after `terraform apply`. If `apply` just finished, wait 90 seconds and re-run the cloud-init step manually via Run Command.

3. **Secret name format.** Secret names are generated as:
   ```
   ${brand}-${codename}-${lowercase_hyphenated_key}
   ```
   For example, with `brand: easecloud` and `codename: magento`:
   - `easecloud-magento-mysql-password`
   - `easecloud-magento-redis-password`
   - `easecloud-magento-admin-path`

   The key transformation is `lower(replace(each.key, "_", "-"))` applied to the `local.secrets` map keys. If you are constructing the secret name manually in a script, ensure underscores are replaced with hyphens and the result is fully lowercase.

4. **Region endpoint.** The `oci secrets` CLI call must target the correct region. Verify `OCI_CLI_REGION` or the `region` value in `~/.oci/config` matches the region where the Vault was created.

---

## WAF blocks legitimate traffic

**Symptom:** Users receive 403 or 429 responses. OCI WAF access logs show the request matched a WAF rule.

### Geo-block (403 with `X-WAF-Block: geo`)

The request's source country code is in `waf.restricted_countries`. Check the OCI WAF access log for the `geolocation.country_code` field.

If the blocked country contains legitimate customers, remove it from the `restricted_countries` list in the environment config YAML and re-apply. Changes to this list take effect on the next `terraform apply`; no infrastructure restart is required.

### Rate limit (429 with `Retry-After: 60`)

The source IP exceeded 100 requests in 60 seconds (or 20 requests in 60 seconds on the admin path).

- If the 429 is coming from a monitoring or uptime check, verify the check is using the health check path. The LB health check path is excluded from rate limiting by the WAF rule condition (`http.request.url.path != '/${health_check_token}'`). A monitoring probe hitting `/` or any other path is subject to the global rate limit.
- If legitimate users are hitting the rate limit, adjust `waf.rate_limit.requests_limit` and re-apply.

### Admin path block (403 with `X-WAF-Block: admin`)

This rule only activates when `waf.admin_allowed_cidrs` is non-empty. The request source IP is not in the allowed CIDR list.

Add your current IP or CIDR to `waf.admin_allowed_cidrs` and re-apply, or temporarily clear the list to disable IP restriction while troubleshooting.

---

## Terraform plan fails with workspace errors

**Symptom:** `terraform plan` exits with an error like `Error reading configuration: file "developer.config.yaml" not found` or a YAML decode error.

**Cause and resolution:**

The project uses `terraform.workspace` to select a config file:

```
developer  → developer.config.yaml
staging    → staging.config.yaml
production → production.config.yaml
```

If the workspace name does not match one of these three values, `local.config_files[local.environment]` returns an empty string and `yamldecode("")` fails.

Verify the active workspace:

```bash
terraform workspace list
terraform workspace select developer
```

If the config file exists but the plan still fails, check for YAML syntax errors. The most common causes are missing quotes around OCID values, incorrect indentation, or a placeholder value (for example `tenancy_ocid: ""`) that a downstream resource expects to be non-empty.

Staging and production config files ship with placeholder values for `oci.tenancy_ocid`, `oci.compartment_ocid`, and `domain`. These must be filled before `terraform apply` is run against those workspaces.

---

## MySQL parameter changes not applied

**Symptom:** After changing a value in `mysql.parameters` and running `terraform apply`, the MySQL parameter does not appear to take effect.

**Cause:** OCI MySQL HeatWave applies configuration changes by creating or updating the `oci_mysql_mysql_configuration` resource, which may require a DB system restart.

- **Dynamic parameters** (for example, `wait_timeout`, `interactive_timeout`, `innodb_lock_wait_timeout`): OCI applies these without a restart. They take effect within seconds of the configuration update completing.
- **Static parameters**: Require a manual DB system restart. After `apply`, go to OCI Console > Databases > MySQL HeatWave > select DB system > More Actions > Restart.

**`innodb_flush_log_at_trx_commit` is not configurable via the OCI provider.** This parameter is listed in `developer.config.yaml` with a comment noting it is not exposed by the OCI Terraform provider. Set it after provisioning using the MySQL CLI:

```sql
-- Connect via Bastion or from a compute instance
SET GLOBAL innodb_flush_log_at_trx_commit = 2;
```

This setting is not persistent across restarts unless applied via the OCI MySQL configuration resource when the provider eventually supports it.

---

## Redis clusters in the same Availability Domain

**Symptom:** Both Redis clusters (`session` and `cache`) are placed in the same AD, reducing resilience.

**Cause:** In `developer.config.yaml`, both clusters have `subnet_index: 0`:

```yaml
redis:
  clusters:
    - name: "session"
      node_count: 1
      subnet_index: 0
    - name: "cache"
      node_count: 1
      subnet_index: 0
```

This is intentional for the `developer` environment, which uses a single AD to minimise cost. In staging and production, distribute the clusters across ADs:

```yaml
redis:
  clusters:
    - name: "session"
      node_count: 1
      subnet_index: 0
    - name: "cache"
      node_count: 1
      subnet_index: 1   # place in second private subnet / second AD
```

Also ensure `vcn.availability_domains_qty: 2` (or higher) so that `pvtsubnet-1` exists. If `availability_domains_qty` is 1, `pvtsubnet-1` is never created and `subnet_index: 1` will cause a Terraform error.

---

## Bastion session creation fails

**Symptom:** Attempting to create a Bastion session through the OCI Console or CLI returns an authorization error or the session creation request is rejected.

**Checklist:**

1. **Client CIDR not allowed.** The Bastion resource restricts session creation to CIDRs listed in `var.bastion_allowed_cidrs`. If this variable is empty (the default), the Bastion accepts any client — but if it has been set, your current egress IP must be in the list.

   Check the active CIDRs:

   ```bash
   terraform output   # if bastion_allowed_cidrs is in outputs
   # or inspect state:
   terraform state show oci_bastion_bastion.this
   ```

   To update, set `var.bastion_allowed_cidrs` and re-apply.

2. **Target subnet is private.** The Bastion targets `oci_core_subnet.private[0]` (the first private subnet). The instance you want to reach must have its primary VNIC in that subnet. Frontend and Varnish instances in `pvtsubnet-1` (index 1) require a port-forward session that also specifies the correct target IP.

3. **No SSH key on the instance.** The OCI Bastion service creates an SSH tunnel to the target instance. If `var.ssh_public_key` was left empty at apply time, no key was injected into the instance and SSH login will fail with `Permission denied (publickey)`. Re-apply with `var.ssh_public_key` set to your public key, then use `terraform apply` to trigger an instance pool recycle, or inject the key manually via OCI Run Command.

---

## terraform destroy fails on Vault

**Symptom:** `terraform destroy` exits with an error like:

```
Error: Instance cannot be destroyed
  Resource oci_kms_vault.this has lifecycle.prevent_destroy set
```

**Cause:** The KMS Vault and its master key both have `lifecycle { prevent_destroy = true }`. This is intentional: an accidental destroy of the Vault would make all secrets permanently unrecoverable, because OCI Vault deletion is irreversible once the pending-deletion period expires.

**Resolution:**

To fully destroy the environment, you must delete the Vault and key manually before running `terraform destroy`:

1. In the OCI Console, go to **Security > Vault**.
2. Select the `${project}-vault`.
3. Choose **Schedule Vault Deletion**. OCI requires a minimum pending-deletion period of 7 days. The Vault (and all its secrets and keys) will be deleted after that period unless you cancel.
4. While the Vault is in `PENDING_DELETION` state, `terraform destroy` will still fail because the resource still exists in OCI. You can either:
   - Remove the Vault and key from Terraform state: `terraform state rm oci_kms_vault.this oci_kms_key.this`, then run `terraform destroy` to remove everything else.
   - Wait until the pending-deletion period completes and the resources disappear from OCI, then run `terraform destroy`.

Alternatively, use the OCI CLI to schedule deletion immediately with the minimum window:

```bash
oci kms management vault schedule-deletion \
  --vault-id <vault_ocid> \
  --time-of-deletion "$(date -u -v+7d '+%Y-%m-%dT%H:%M:%SZ')"
```
