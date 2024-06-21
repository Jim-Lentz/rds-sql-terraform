data "aws_availability_zones" "available" {}

locals {
  name    = "complete-mssql"
  region  = "us-west-2"
  #region2 = "eu-central-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Name       = local.name
    Example    = local.name
    Repository = "https://github.com/terraform-aws-modules/terraform-aws-rds"
  }
}

module "vpc" {
  source = "cloudposse/vpc/aws"
  # Cloud Posse recommends pinning every module to a specific version
  # version     = "x.x.x"
  namespace = "eg"
  stage     = "test"
  name      = "app"

  ipv4_primary_cidr_block = "10.0.0.0/16"

  assign_generated_ipv6_cidr_block = false
}

module "dynamic_subnets" {
  source = "cloudposse/dynamic-subnets/aws"
  # Cloud Posse recommends pinning every module to a specific version
  # version     = "x.x.x"
  namespace          = "eg"
  stage              = "test"
  name               = "app"
  availability_zones = ["us-west-2a","us-west-2b","us-west-2c"]
  vpc_id             = module.vpc.vpc_id
  igw_id             = [module.vpc.igw_id]
  ipv4_cidr_block    = ["10.0.0.0/16"]
  nat_gateway_enabled = false
}

module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier = "demodb"
/*
  engine            = "sqlserver-ee"
  engine_version    = "14.00.3465.1.v1"
  instance_class    = "db.m5.large"
  family            = "sqlserver-ee-14.00"
  major_engine_version = "14.00"
  */

  # testing with this setup to see if it will work
  engine               = "sqlserver-ex"
  engine_version       = "15.00"
  family               = "sqlserver-ex-15.0" # DB parameter group
  major_engine_version = "15.00"             # DB option group
  instance_class       = "db.t3.large"
  storage_encrypted    = false

# End testing block

  allocated_storage = 40
  storage_type = "gp3"
  
  create_db_parameter_group = false # added as a test to see if it would work
  license_model             = "license-included"
 # db_name  = "demodb" # trying null for testing 
  username = "user123"
  port     = "1433"

  domain               = aws_directory_service_directory.demo.id
  domain_iam_role_name = aws_iam_role.rds_ad_auth.name

  skip_final_snapshot = true

  iam_database_authentication_enabled = false #true

  vpc_security_group_ids = [module.vpc.vpc_default_security_group_id] #["sg-090ba5281c5a9b4db"]

  maintenance_window = "Mon:00:00-Mon:03:00"
  backup_window      = "03:00-06:00"

  # Enhanced Monitoring - see example for details on how to create the role
  # by yourself, in case you don't want to create it automatically
  monitoring_interval    = "30"
  monitoring_role_name   = "MyRDSMonitoringRole"
  create_monitoring_role = true

  tags = {
    Owner       = "user"
    Environment = "dev"
  }

  # DB subnet group
  create_db_subnet_group = true
  subnet_ids             = [module.dynamic_subnets.private_subnet_ids[0], module.dynamic_subnets.private_subnet_ids[1], module.dynamic_subnets.private_subnet_ids[2]] #[module.dynamic_subnets.private[0], module.dynamic_subnets.private[1], module.dynamic_subnets.private[2]]

  
/* Removing for testing. This will need to be changed for SQL if it is needed
  # DB parameter group
  family = "mysql5.7"

  # DB option group
  major_engine_version = "5.7"

  # Database Deletion Protection
  deletion_protection = false

  parameters = [
    {
      name  = "character_set_client"
      value = "utf8mb4"
    },
    {
      name  = "character_set_server"
      value = "utf8mb4"
    }
  ]

  options = [
    {
      option_name = "MARIADB_AUDIT_PLUGIN"

      option_settings = [
        {
          name  = "SERVER_AUDIT_EVENTS"
          value = "CONNECT"
        },
        {
          name  = "SERVER_AUDIT_FILE_ROTATIONS"
          value = "37"
        },
      ]
    },
  ]
  */
}

# Adding an instance to manage DMS with

resource "aws_security_group" "rds_management_instance" {
  name        = "sql_instance"
  description = "Allow inbound traffic for SQL and rdp from Jims IP and all outbound traffic"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "allow_traffic"
  }
}

resource "aws_vpc_security_group_ingress_rule" "allow_rds_1" {
  security_group_id = aws_security_group.rds_management_instance.id
  cidr_ipv4         = "4.42.1.190/32" # Jim's IP
  from_port         = 3389
  ip_protocol       = "tcp"
  to_port           = 3389
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv4_1" {
  security_group_id = aws_security_group.rds_management_instance.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

module "rds_management_instance" {
  source = "cloudposse/ec2-instance/aws"
  # Cloud Posse recommends pinning every module to a specific version
  # version     = "x.x.x"
  ssh_key_pair                = "jimspemkey" #module.ssh_key_pair.key_name
  vpc_id                      = module.vpc.vpc_id #var.vpc_id
  security_groups             = [aws_security_group.rds_management_instance.id, module.vpc.vpc_default_security_group_id]
  subnet                      = module.dynamic_subnets.public_subnet_ids[0]
  associate_public_ip_address = false
  name                        = "RdsManagmentServer"
  namespace                   = "sql"
  stage                       = "dev"
  instance_type               = "t3.xlarge"
  ami                         = "ami-0fc134ad9955f3e08" # custome AMI with SQL tools installed
  root_volume_size            = 100
  ebs_volume_size             = 100
  additional_ips_count        = 1
  ebs_volume_count            = 1
}

################################################################################
# IAM Role for Windows Authentication
################################################################################

data "aws_iam_policy_document" "rds_assume_role" {
  statement {
    sid = "AssumeRole"

    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_ad_auth" {
  name                  = "demo-rds-ad-auth"
  description           = "Role used by RDS for Active Directory authentication and authorization"
  force_detach_policies = true
  assume_role_policy    = data.aws_iam_policy_document.rds_assume_role.json

  #tags = local.tags
}

resource "aws_iam_role_policy_attachment" "rds_directory_services" {
  role       = aws_iam_role.rds_ad_auth.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSDirectoryServiceAccess"
}

################################################################################
# AWS Directory Service (Acitve Directory)
################################################################################

resource "aws_directory_service_directory" "demo" {
  name     = "corp.demo.com"
  password = "SuperSecretPassw0rd"
  edition  = "Standard"
  type     = "MicrosoftAD"

  vpc_settings {
    vpc_id = module.vpc.vpc_id
    # Only 2 subnets, must be in different AZs
    subnet_ids = [module.dynamic_subnets.private_subnet_ids[0], module.dynamic_subnets.private_subnet_ids[1]] # slice(tolist(module.vpc.database_subnets), 0, 2)
  }

  #tags = local.tags
}