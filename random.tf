

///////////////////////////////////////////////////////////[ RANDOM VALUES ]/////////////////////////////////////////////////////

resource "random_password" "this" {
  for_each         = toset(local.env.password)
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}:?"
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 2
}

resource "random_string" "this" {
  for_each = toset(local.env.string)
  length   = 16
  special  = false
}

resource "random_uuid" "this" {}
