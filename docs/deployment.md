# Deployment Guide

Step-by-step guide for deploying Magento 2 OCI Terraform from scratch to a running environment.

---

## Prerequisites checklist

Before running any Terraform commands, confirm the following.

**Tooling**

- Terraform >= 1.9 (`terraform version`)
- OCI CLI >= 3.x (`oci --version`)
- A key pair for OCI API authentication (see Authentication below)

**OCI tenancy**

- An OCI tenancy with A1 Flex instance limits. The free-tier A1 quota (4 OCPUs / 24 GB total per tenancy) may be exhausted by a single developer workspace. Request a limit increase under Limits, Quotas and Usage if needed.
- A compartment dedicated to this project. Using the root compartment works but is not recommended.
- IAM policies granting your user (or group) `manage` access to the following resource families in the target compartment:

```hcl
Allow group <your-group> to manage all-resources in compartment <your-compartment>
```

For least-privilege, the minimum set of families required is:

```
core-family              (VCN, subnets, NSG, instances, instance pools, autoscaling)
load-balancers           (public and internal LB, backend sets)
waf-family               (WAF policies)
dns                      (public zones, records)
object-family            (buckets, objects)
file-family              (file systems, mount targets)
mysql-family             (DB systems, configurations, backups)
redis-cluster-family     (Redis clusters)
opensearch-family        (OpenSearch clusters)
vaults                   (KMS vault, keys)
secret-family            (Vault secrets)
bastion-family           (Bastion service)
ons-family               (notification topics, subscriptions)
events                   (Events rules)
monitoring               (alarms)
budgets                  (budgets)
```

At the tenancy level your user also needs:

```
Allow group <your-group> to read objectstorage-namespaces in tenancy
Allow group <your-group> to read compartments in tenancy
Allow group <your-group> to read availability-domains in tenancy
Allow group <your-group> to manage tag-namespaces in tenancy
```

---

## Initial setup

```bash
git clone https://github.com/easecloud/magento2-oci-terraform.git
cd magento2-oci-terraform

# Copy the developer config and fill in your values
cp developer.config.yaml myproject-developer.config.yaml
```

Open `myproject-developer.config.yaml` and set at minimum:

```yaml
brand: mystore          # used in all OCI resource display names
codename: magento       # combined: mystore-magento (the project prefix)
domain: store.example.com
admin_email: ops@example.com

oci:
  region: us-ashburn-1
  tenancy_ocid: "ocid1.tenancy.oc1..aaa..."      # from OCI Console → Profile → Tenancy
  compartment_ocid: "ocid1.compartment.oc1..aaa..." # from Identity → Compartments
```

The workspace name must match the config file prefix. If you created `myproject-developer.config.yaml`, the workspace must be named `myproject-developer`. For the bundled three-environment setup the filenames and workspace names are `developer`, `staging`, and `production`.

---

## OCI authentication

### Option A — Local development (~/.oci/config)

Run `oci setup config` and follow the prompts, or write the file manually:

```ini
[DEFAULT]
user=ocid1.user.oc1..aaa...
fingerprint=aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99
tenancy=ocid1.tenancy.oc1..aaa...
region=us-ashburn-1
key_file=~/.oci/oci_api_key.pem
```

Generate the API key pair if you have not already:

```bash
mkdir -p ~/.oci
openssl genrsa -out ~/.oci/oci_api_key.pem 2048
chmod 600 ~/.oci/oci_api_key.pem
openssl rsa -pubout -in ~/.oci/oci_api_key.pem -out ~/.oci/oci_api_key_public.pem
```

Upload `oci_api_key_public.pem` in the OCI Console under Profile → API Keys.

### Option B — CI/CD (environment variables)

Set these variables in your CI environment (GitHub Actions secrets, GitLab CI variables, etc.):

```
OCI_CLI_USER        ocid1.user.oc1..aaa...
OCI_CLI_TENANCY     ocid1.tenancy.oc1..aaa...
OCI_CLI_FINGERPRINT aa:bb:cc:...
OCI_CLI_KEY_CONTENT -----BEGIN RSA PRIVATE KEY-----\n...
OCI_CLI_REGION      us-ashburn-1
```

`OCI_CLI_KEY_CONTENT` should contain the full PEM private key with literal `\n` newlines, or exported as a base64 blob depending on your CI platform's secret handling.

The Terraform OCI provider reads these variables automatically — no `provider` block changes needed.

---

## First deployment

```bash
terraform init

# Workspace name must match the config file prefix
terraform workspace new developer

terraform plan -out developer.plan
```

Review the plan output. On a fresh developer workspace, Terraform creates approximately 80 resources. The dependency order is:

1. VCN, subnets, internet gateway, NAT gateway, service gateway, route tables
2. Network Security Groups and their rules
3. KMS Vault and master key (AES-256)
4. Vault secrets (generated passwords and tokens)
5. Object Storage buckets (`{project}-media`, `{project}-media-optimized`, `{project}-system`, `{project}-backup`)
6. OCI File Storage file systems and mount targets (one per availability domain)
7. MySQL HeatWave DB system and configuration (takes 10–15 minutes)
8. OCI Cache Redis clusters (`{project}-redis-session`, `{project}-redis-cache`)
9. OCI OpenSearch cluster
10. DNS zone and records
11. Instance configurations (launch templates for Varnish and Frontend)
12. Instance Pools and Autoscaling configurations
13. Internal load balancer (private, Varnish → Frontend)
14. Public load balancer, WAF policy, and WAF association
15. Bastion service
16. OCI Monitoring alarms, ONS notification topic, and email subscription
17. OCI Events rule for release deployments
18. Budget

```bash
terraform apply developer.plan
```

The first apply takes 20–35 minutes, dominated by MySQL provisioning. Subsequent applies (config changes, scaling) complete in 2–5 minutes.

---

## Post-apply steps

After `terraform apply` completes:

```bash
terraform output
```

Key values to act on immediately:

```
load_balancer_ip  = "129.xxx.xxx.xxx"
mysql_endpoint    = "mystore-magento.private.mysql.vcn.oraclevcn.com"
redis_endpoints   = { session = "10.x.x.x", cache = "10.x.x.x" }
opensearch_endpoint = "https://amaaaaa...search.oci.oraclecloud.com:9200"
```

**DNS A record**

Point your domain's A record to `load_balancer_ip`. OCI DNS public records are created automatically for `domain` and `www.domain`, but your registrar's NS records must delegate to OCI's nameservers for those records to resolve:

```
ns1.p68.dns.oraclecloud.net
ns2.p68.dns.oraclecloud.net
ns3.p68.dns.oraclecloud.net
ns4.p68.dns.oraclecloud.net
```

If you are managing DNS elsewhere, add an A record pointing `domain` and `www.domain` to `load_balancer_ip`.

**Email subscription confirmation**

OCI ONS sends a confirmation email to `admin_email`. Click the link to activate alarm and event notifications.

**Enabling HTTPS**

Supply your certificate and private key, then re-apply:

```bash
export TF_VAR_ssl_certificate_pem="$(cat fullchain.pem)"
export TF_VAR_ssl_private_key_pem="$(cat privkey.pem)"

terraform plan -out developer.plan
terraform apply developer.plan
```

`ssl_certificate_pem` should be the full chain (leaf + intermediates). The listener is switched from HTTP to HTTPS in-place; HTTP requests are redirected to HTTPS automatically. The certificate resource is named `{project}-cert`.

---

## Magento application deployment

The Ansible playbooks bootstrapped by cloud-init install Nginx, PHP-FPM 8.2, and configure the OS. They do not deploy Magento code. Code deployment is event-driven via OCI Object Storage and Events.

**How it works**

1. Upload a release zip to the `{project}-system` bucket under the `releases/` prefix:

```bash
oci os object put \
  --bucket-name mystore-magento-system \
  --name releases/mystore-magento-2.4.7-p1.zip \
  --file ./mystore-magento-2.4.7-p1.zip \
  --auth instance_principal
```

2. The OCI Events rule `{project}-release-deploy` fires on `com.oraclecloud.objectstorage.createobject` events for the `{project}-system` bucket. It publishes a message to the ONS topic `{project}-notifications`.

3. Your deployment consumer (a Function, a Notification webhook, or a custom subscriber) receives the notification and runs the deploy procedure on the instances. The notification message includes the bucket name and object name.

The Events rule triggers on any object created in the bucket, not only objects under `releases/`. Scope your consumer to filter on the object name prefix if needed.

**Playbook upload**

The cloud-init scripts pull Ansible playbooks from the `{project}-system` bucket at instance boot time:

```
ansible/playbooks/frontend.yml
ansible/playbooks/varnish.yml
```

Upload updated playbooks to that path in the system bucket to have new instances pick up changes on next boot.

---

## Multiple environments

Each environment is a Terraform workspace with its own state file and its own config YAML. Resources in different workspaces are fully independent.

```bash
# Staging
cp developer.config.yaml staging.config.yaml
# Edit staging.config.yaml: increase compute sizes, enable Redis HA, etc.
terraform workspace new staging
terraform plan -out staging.plan
terraform apply staging.plan

# Production
cp staging.config.yaml production.config.yaml
# Edit production.config.yaml: HA MySQL, 3-node Redis per cluster, etc.
terraform workspace new production
terraform plan -out production.plan
terraform apply production.plan

# Switch between environments
terraform workspace select developer
terraform workspace select production
```

Resource names are prefixed with `{brand}-{codename}` (the project local), so resources from different workspaces can coexist in the same compartment without name collisions only if you differentiate by environment name in the brand or codename.

---

## Destroying infrastructure

```bash
terraform workspace select developer
terraform destroy
```

Most resources destroy cleanly. Two resources have `prevent_destroy = true` and will block the destroy:

- `oci_kms_vault.this` — the `{project}-vault` KMS vault
- `oci_kms_key.this` — the `{project}-master-key` AES key

This protects secrets from accidental deletion. To proceed with a full teardown:

1. In the OCI Console, navigate to Security → Vaults → `{project}-vault`.
2. Schedule the vault for deletion (minimum 7-day waiting period enforced by OCI).
3. Or delete the master key first, then the vault.

Via OCI CLI:

```bash
# Schedule key deletion (minimum 7 days)
oci kms management key schedule-deletion \
  --key-id <key-ocid> \
  --time-of-deletion "$(date -u -v+8d +%Y-%m-%dT%H:%M:%SZ)" \
  --endpoint <vault-management-endpoint>

# After the waiting period, schedule vault deletion
oci kms management vault delete \
  --vault-id <vault-ocid>
```

After removing the `prevent_destroy` lifecycle blocks (or after the vault has been deleted externally), re-run `terraform destroy` to remove the remaining state entries.
