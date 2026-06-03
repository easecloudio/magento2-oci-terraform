

///////////////////////////////////////////////////////////[ OUTPUTS ]/////////////////////////////////////////////////////

output "load_balancer_ip" {
  description = "Public IP address of the OCI Load Balancer"
  value       = oci_load_balancer_load_balancer.this.ip_address_details[0].ip_address
}

output "mysql_endpoint" {
  description = "MySQL HeatWave DB system endpoint"
  value       = oci_mysql_mysql_db_system.this.endpoints[0].hostname
  sensitive   = false
}

output "redis_endpoints" {
  description = "Redis cluster primary endpoints keyed by name (session, cache)"
  value = {
    for k, v in oci_redis_redis_cluster.this :
    k => v.primary_endpoint_ip_address
  }
}

output "object_storage_buckets" {
  description = "Object Storage bucket names keyed by type (media, media-optimized, system, backup)"
  value = {
    for k, v in oci_objectstorage_bucket.this :
    k => v.name
  }
}

output "opensearch_endpoint" {
  description = "OCI OpenSearch cluster API endpoint"
  value       = "https://${oci_opensearch_opensearch_cluster.this.opensearch_fqdn}:9200"
}

output "nfs_mount_target_ip" {
  description = "Private IP of the OCI File Storage mount target"
  value       = oci_file_storage_mount_target.this.private_ip_ids
}

output "project" {
  description = "Project name derived from brand + codename"
  value       = local.project
}

output "environment" {
  description = "Active Terraform workspace / environment name"
  value       = local.environment
}
