

///////////////////////////////////////////////////////////[ REDIS CACHE ]/////////////////////////////////////////////////////

resource "oci_redis_redis_cluster" "this" {
  for_each           = local.redis_clusters
  compartment_id     = local.env.oci.compartment_ocid
  display_name       = "${local.project}-redis-${each.key}"
  node_count         = each.value.node_count
  node_memory_in_gbs = local.env.redis.node_memory_in_gbs
  software_version   = local.env.redis.software_version
  subnet_id          = oci_core_subnet.private[each.value.subnet_index].id
  nsg_ids            = [oci_core_network_security_group.cache.id]
  # auth_token is not exposed by oci_redis_redis_cluster in provider ~> 6.0.
  # Redis AUTH is configured via oci_redis_oci_cache_user (available in newer provider
  # versions). The generated password is stored in the OCI Vault secret
  # "${local.project}-redis-password" and should be applied after cluster creation.
  freeform_tags      = local.default_tags
}
