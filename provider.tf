terraform {
  required_version = ">= 1.9"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "oci" {
  region = local.env.oci.region
}

provider "random" {}
