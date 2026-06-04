
///////////////////////////////////////////////////////////[ ANSIBLE PLAYBOOK OBJECTS ]/////////////////////////////////////////////////////

# Upload Ansible playbooks to the system Object Storage bucket so cloud-init
# can download them at instance boot time via the OCI CLI with instance_principal auth.

resource "oci_objectstorage_object" "ansible_playbooks" {
  for_each   = { for f in ["frontend", "varnish", "cron"] : f => f }
  namespace  = data.oci_objectstorage_namespace.this.namespace
  bucket     = "${local.project}-system"
  object     = "ansible/playbooks/${each.key}.yml"
  source     = "${path.module}/ansible/playbooks/${each.key}.yml"
  depends_on = [oci_objectstorage_bucket.this]
}
