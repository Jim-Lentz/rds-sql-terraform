
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

  engine            = "mysql"
  engine_version    = "5.7"
  instance_class    = "db.m5.large"
  allocated_storage = 5

  db_name  = "demodb"
  username = "user"
  port     = "3306"

  skip_final_snapshot = true

  iam_database_authentication_enabled = true

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
  security_groups             = [aws_security_group.rds_management_instance.id]
  subnet                      = module.dynamic_subnets.public_subnet_ids[0]
  associate_public_ip_address = false
  name                        = "sqlManagmentServer"
  namespace                   = "sqp"
  stage                       = "dev"
  instance_type               = "t2.large"
  ami                         = "ami-07e278fe6c43b6aba" 
  root_volume_size            = 100
  ebs_volume_size             = 100
  additional_ips_count        = 1
  ebs_volume_count            = 1
 
}