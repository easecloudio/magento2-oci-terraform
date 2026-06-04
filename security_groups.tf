
////////////////////////////////////////////////////////[ NETWORK SECURITY GROUPS ]/////////////////////////////////////////

# # ---------------------------------------------------------------------------------------------------------------------#
# Load Balancer NSG — allows HTTP/HTTPS from internet
# # ---------------------------------------------------------------------------------------------------------------------#
resource "oci_core_network_security_group" "lb" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-lb-nsg"
  freeform_tags  = local.default_tags
}

resource "oci_core_network_security_group_security_rule" "lb_ingress_http" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_ingress_https" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_egress_all" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Compute NSG — allows traffic from LB on 80/8080, internal VCN for Varnish→Frontend
# # ---------------------------------------------------------------------------------------------------------------------#
resource "oci_core_network_security_group" "compute" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-compute-nsg"
  freeform_tags  = local.default_tags
}

resource "oci_core_network_security_group_security_rule" "compute_ingress_from_lb_http" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "compute_ingress_from_lb_imgproxy" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 8080
      max = 8080
    }
  }
}

resource "oci_core_network_security_group_security_rule" "compute_ingress_internal" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.env.vcn.cidr_block
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "compute_egress_all" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Internal LB NSG — allows Varnish→Frontend traffic on port 8080
# # ---------------------------------------------------------------------------------------------------------------------#
resource "oci_core_network_security_group" "internal_lb" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-internal-lb-nsg"
  freeform_tags  = local.default_tags
}

resource "oci_core_network_security_group_security_rule" "internal_lb_ingress" {
  network_security_group_id = oci_core_network_security_group.internal_lb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.compute.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 8080
      max = 8080
    }
  }
}

resource "oci_core_network_security_group_security_rule" "internal_lb_egress" {
  for_each                  = toset(local.private_subnet_cidrs)
  network_security_group_id = oci_core_network_security_group.internal_lb.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = each.value
  destination_type          = "CIDR_BLOCK"
}

resource "oci_core_network_security_group_security_rule" "compute_ingress_from_internal_lb" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.internal_lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 8080
      max = 8080
    }
  }
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Database NSG — allows MySQL from compute only
# # ---------------------------------------------------------------------------------------------------------------------#
resource "oci_core_network_security_group" "database" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-db-nsg"
  freeform_tags  = local.default_tags
}

resource "oci_core_network_security_group_security_rule" "database_ingress_mysql" {
  network_security_group_id = oci_core_network_security_group.database.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.compute.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 3306
      max = 3306
    }
  }
}

resource "oci_core_network_security_group_security_rule" "database_egress_all" {
  network_security_group_id = oci_core_network_security_group.database.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Cache NSG — allows Redis from compute only
# # ---------------------------------------------------------------------------------------------------------------------#
resource "oci_core_network_security_group" "cache" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-cache-nsg"
  freeform_tags  = local.default_tags
}

resource "oci_core_network_security_group_security_rule" "cache_ingress_redis" {
  network_security_group_id = oci_core_network_security_group.cache.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.compute.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 6379
      max = 6379
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cache_egress_all" {
  network_security_group_id = oci_core_network_security_group.cache.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# # ---------------------------------------------------------------------------------------------------------------------#
# NFS NSG — allows NFS (2049) from compute only
# # ---------------------------------------------------------------------------------------------------------------------#
resource "oci_core_network_security_group" "nfs" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-nfs-nsg"
  freeform_tags  = local.default_tags
}

resource "oci_core_network_security_group_security_rule" "nfs_ingress" {
  network_security_group_id = oci_core_network_security_group.nfs.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.compute.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 2049
      max = 2049
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nfs_egress_all" {
  network_security_group_id = oci_core_network_security_group.nfs.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# # ---------------------------------------------------------------------------------------------------------------------#
# OpenSearch NSG — allows 9200/9300 from compute only
# # ---------------------------------------------------------------------------------------------------------------------#
resource "oci_core_network_security_group" "opensearch" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-opensearch-nsg"
  freeform_tags  = local.default_tags
}

resource "oci_core_network_security_group_security_rule" "opensearch_ingress_api" {
  network_security_group_id = oci_core_network_security_group.opensearch.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.compute.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 9200
      max = 9200
    }
  }
}

resource "oci_core_network_security_group_security_rule" "opensearch_ingress_cluster" {
  network_security_group_id = oci_core_network_security_group.opensearch.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.opensearch.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 9300
      max = 9300
    }
  }
}

resource "oci_core_network_security_group_security_rule" "opensearch_egress_all" {
  network_security_group_id = oci_core_network_security_group.opensearch.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# # ---------------------------------------------------------------------------------------------------------------------#
# Cron NSG — egress only; no LB ingress (cron has no web listeners)
# # ---------------------------------------------------------------------------------------------------------------------#
resource "oci_core_network_security_group" "cron" {
  compartment_id = local.env.oci.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.project}-cron-nsg"
  freeform_tags  = local.default_tags
}

resource "oci_core_network_security_group_security_rule" "cron_egress_all" {
  network_security_group_id = oci_core_network_security_group.cron.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# Allow cron → backing services (mirroring the compute NSG rules below)
resource "oci_core_network_security_group_security_rule" "database_ingress_mysql_cron" {
  network_security_group_id = oci_core_network_security_group.database.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.cron.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 3306
      max = 3306
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cache_ingress_redis_cron" {
  network_security_group_id = oci_core_network_security_group.cache.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.cron.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 6379
      max = 6379
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nfs_ingress_cron" {
  network_security_group_id = oci_core_network_security_group.nfs.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.cron.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 2049
      max = 2049
    }
  }
}

resource "oci_core_network_security_group_security_rule" "opensearch_ingress_api_cron" {
  network_security_group_id = oci_core_network_security_group.opensearch.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.cron.id
  source_type               = "NETWORK_SECURITY_GROUP"
  tcp_options {
    destination_port_range {
      min = 9200
      max = 9200
    }
  }
}
