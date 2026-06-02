# Magento 2 OCI Terraform

Deploy a production-ready Magento 2 infrastructure on Oracle Cloud Infrastructure using Terraform.

## Prerequisites

### OCI Authentication

The OCI Terraform provider authenticates via the OCI CLI config file or environment variables.

**Local development** — create `~/.oci/config` with your credentials:

```ini
[DEFAULT]
user=ocid1.user.oc1..example
fingerprint=xx:xx:xx:xx
tenancy=ocid1.tenancy.oc1..example
region=us-ashburn-1
key_file=~/.oci/oci_api_key.pem
```

Generate an API key pair in the OCI Console under **Profile → API Keys**, then paste the public key there and save the private key to `~/.oci/oci_api_key.pem`.

**CI/CD** — set the following environment variables (no config file needed):

| Variable | Description |
|---|---|
| `OCI_CLI_USER` | User OCID |
| `OCI_CLI_TENANCY` | Tenancy OCID |
| `OCI_CLI_FINGERPRINT` | API key fingerprint |
| `OCI_CLI_KEY_CONTENT` | PEM private key (raw content) |
| `OCI_CLI_REGION` | OCI region (e.g. `us-ashburn-1`) |

Full documentation coming soon.
