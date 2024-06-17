terraform {
  required_version = "~> 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.37.0"
    }
  }
  cloud {
    organization = "TerraformBootCampJimLentzNew"
    workspaces {
      name = "rds-sql-terraform"
    }
  }
}
