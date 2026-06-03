

///////////////////////////////////////////////////////////[ REDIS CACHE ]/////////////////////////////////////////////////////

resource "oci_redis_redis_cluster" "this" {
  for_each           = toset(local.env.redis.name)
  compartment_id     = local.env.oci.compartment_ocid
  display_name       = "${local.project}-redis-${each.key}"
  node_count         = local.env.redis.node_count
  node_memory_in_gbs = local.env.redis.node_memory_in_gbs
  software_version   = local.env.redis.software_version
  subnet_id          = oci_core_subnet.private[0].id
  nsg_ids            = [oci_core_network_security_group.cache.id]
  freeform_tags      = local.default_tags
}
