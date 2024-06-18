#
# Create network resources
#
module "dms_vpc" {
  source = "cloudposse/vpc/aws"
  # Cloud Posse recommends pinning every module to a specific version
  # version     = "x.x.x"
  namespace = "eg"
  stage     = "test"
  name      = "app"

  ipv4_primary_cidr_block = "10.1.0.0/16"

  assign_generated_ipv6_cidr_block = false
}

module "dms_subnets" {
  source = "cloudposse/dynamic-subnets/aws"
  # Cloud Posse recommends pinning every module to a specific version
  # version     = "x.x.x"
  namespace          = "eg"
  stage              = "test"
  name               = "app"
  availability_zones = ["us-west-2a","us-west-2b","us-west-2c"]
  vpc_id             = module.dms_vpc.vpc_id
  igw_id             = [module.dms_vpc.igw_id]
  ipv4_cidr_block    = ["10.1.0.0/16"]
  nat_gateway_enabled = false
}

resource "aws_security_group" "sql_instance" {
  name        = "sql_instance"
  description = "Allow inbound traffic for SQL and SSH and all outbound traffic"
  vpc_id      = module.dms_vpc.vpc_id

  tags = {
    Name = "allow_traffic"
  }
}

resource "aws_vpc_security_group_ingress_rule" "allow_sql" {
  security_group_id = aws_security_group.sql_instance.id
  cidr_ipv4         = module.dms_vpc.vpc_cidr_block
  from_port         = 1433
  ip_protocol       = "tcp"
  to_port           = 1433
}

resource "aws_vpc_security_group_ingress_rule" "allow_rds" {
  security_group_id = aws_security_group.sql_instance.id
  cidr_ipv4         = module.dms_vpc.vpc_cidr_block
  from_port         = 3389
  ip_protocol       = "tcp"
  to_port           = 3389
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.sql_instance.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}


module "ssh_key_pair" {
  source = "cloudposse/key-pair/aws"
  # Cloud Posse recommends pinning every module to a specific version
  # version     = "x.x.x"
  namespace             = "eg"
  stage                 = "prod"
  name                  = "app"
  ssh_public_key_path   = "/secrets"
  generate_ssh_key      = "true"
  private_key_extension = ".pem"
  public_key_extension  = ".pub"
}

#
# Create a SQL Server instance
#

module "sql_instance" {
  source = "cloudposse/ec2-instance/aws"
  # Cloud Posse recommends pinning every module to a specific version
  # version     = "x.x.x"
  ssh_key_pair                = module.ssh_key_pair.key_name
  vpc_id                      = module.dms_vpc.vpc_id #var.vpc_id
  security_groups             = [aws_security_group.sql_instance.id]
  subnet                      = module.dms_subnets.private_subnet_ids[0]
  associate_public_ip_address = false
  name                        = "sqlserver"
  namespace                   = "eg"
  stage                       = "dev"
  instance_type               = "t3.xlarge"
  ami                         = "ami-0b67457830f2570dc"
  root_volume_size            = 100
  ebs_volume_size             = 100
  additional_ips_count        = 1
  ebs_volume_count            = 1
 /* security_group_rules = [
    {
      type        = "egress"
      from_port   = 0
      to_port     = 65535
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    },
    {
      type        = "ingress"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    },
    {
      type        = "ingress"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    },
    {
      type        = "ingress"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    },
    {
      type        = "ingress"
      from_port   = 53
      to_port     = 53
      protocol    = "udp"
      cidr_blocks = ["0.0.0.0/0"]
    },
  ]
  */
}

module "database_migration_service" {
  source  = "terraform-aws-modules/dms/aws"
  version = "~> 2.0"

  # Subnet group
  repl_subnet_group_name        = "dms-subnet-group"
  repl_subnet_group_description = "DMS Subnet group"
  repl_subnet_group_subnet_ids  = [module.dms_subnets.private_subnet_ids[0], module.dms_subnets.private_subnet_ids[1], module.dms_subnets.private_subnet_ids[2]]

  # Instance
  repl_instance_allocated_storage            = 64
  repl_instance_auto_minor_version_upgrade   = true
  repl_instance_allow_major_version_upgrade  = true
  repl_instance_apply_immediately            = true
  repl_instance_engine_version               = "3.5.2"
  repl_instance_multi_az                     = false ## change to true for production
  repl_instance_preferred_maintenance_window = "sun:10:30-sun:14:30"
  repl_instance_publicly_accessible          = false
  repl_instance_class                        = "dms.t3.large"
  repl_instance_id                           = "dms-instance"
  repl_instance_vpc_security_group_ids       = [aws_security_group.sql_instance.id] #["sg-12345678"] # still need to figure out

  endpoints = {
    source = {
      database_name               = "sql-instance"
      endpoint_id                 = "sql-source"
      endpoint_type               = "source"
      engine_name                 = "sqlserver"
      extra_connection_attributes = "heartbeatFrequency=1;"
      username                    = "dms_migration"
      password                    = "youShouldPickABetterPassword123!"
      port                        = 1433
      server_name                 = module.sql_instance.name #"dms-ex-src.cluster-abcdefghijkl.us-east-1.rds.amazonaws.com"
      ssl_mode                    = "none"
      tags                        = { EndpointType = "source" }
    }

    destination = {
      database_name = "sql-rds"
      endpoint_id   = "sql-destination"
      endpoint_type = "target"
      engine_name   = "sqlserver"
      username      = "dms_migration"
      password      = "passwordsDoNotNeedToMatch789?"
      port          = 1433
      server_name   = module.db.db_instance_name # "dms-ex-dest.cluster-abcdefghijkl.us-east-1.rds.amazonaws.com"
      ssl_mode      = "none"
      tags          = { EndpointType = "destination" }
    }
  }

/* removed during testing - need the json files
  replication_tasks = {
    cdc_ex = {
      replication_task_id       = "example-cdc"
      migration_type            = "cdc"
      replication_task_settings = file("task_settings.json")
      table_mappings            = file("table_mappings.json")
      source_endpoint_key       = "source"
      target_endpoint_key       = "destination"
      tags                      = { Task = "SQL to RDS SQL" }
    }
  }
*/

/* removed during testing
  event_subscriptions = {
    instance = {
      name                             = "instance-events"
      enabled                          = true
      instance_event_subscription_keys = ["example"]
      source_type                      = "replication-instance"
      sns_topic_arn                    = "arn:aws:sns:us-east-1:012345678910:example-topic"
      event_categories                 = [
        "failure",
        "creation",
        "deletion",
        "maintenance",
        "failover",
        "low storage",
        "configuration change"
      ]
    }
    task = {
      name                         = "task-events"
      enabled                      = true
      task_event_subscription_keys = ["cdc_ex"]
      source_type                  = "replication-task"
      sns_topic_arn                = "arn:aws:sns:us-east-1:012345678910:example-topic"
      event_categories             = [
        "failure",
        "state change",
        "creation",
        "deletion",
        "configuration change"
      ]
    }
  }
*/
  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}