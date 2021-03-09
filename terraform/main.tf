#TODO: add s3 status bucket

provider "aws" {
  region                  = "eu-west-3"
  profile                 = "default"
}

resource "aws_key_pair" "ec2kepair" {
  key_name   = "ec2kepair"
  public_key = file("key.pub")
}

###########
#create VPC
###########

resource "aws_vpc" "vpc" {
    cidr_block = "10.0.0.0/24"
    enable_dns_support   = true
    enable_dns_hostnames = true
    tags       = {
        Name = "Wordpress VPC"
    }
}

##################################################################
#allow communication between instances in our VPC and the internet
##################################################################
resource "aws_internet_gateway" "internet_gateway" {
    vpc_id = aws_vpc.vpc.id
}
##############
#create subnet
##############
resource "aws_subnet" "pub_subnet" {
    vpc_id                  = aws_vpc.vpc.id
    cidr_block              = "10.0.0.0/24"
}

##################
#add routing table
##################
resource "aws_route_table" "public" {
    vpc_id = aws_vpc.vpc.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.internet_gateway.id
    }
}

resource "aws_route_table_association" "route_table_association" {
    subnet_id      = aws_subnet.pub_subnet.id
    route_table_id = aws_route_table.public.id
}


####################################################
#define security groups for db backend and webserver
####################################################
resource "aws_security_group" "ecs_sg" {
    vpc_id      = aws_vpc.vpc.id
    name        = "ecs security group"

    ingress {
        from_port       = 22
        to_port         = 22
        protocol        = "tcp"
        cidr_blocks     = ["0.0.0.0/0"]
    }

    ingress {
        from_port       = 80
        to_port         = 80
        protocol        = "tcp"
        cidr_blocks     = ["0.0.0.0/0"]
    }

    egress {
        from_port       = 0
        to_port         = 65535
        protocol        = "tcp"
        cidr_blocks     = ["0.0.0.0/0"]
    }
}

resource "aws_security_group" "rds_sg" {
    vpc_id      = aws_vpc.vpc.id
    name        = "mysql security group"

    ingress {
        from_port       = 22
        to_port         = 22
        protocol        = "tcp"
        cidr_blocks     = ["0.0.0.0/0"]
    }

    ingress {
        protocol        = "tcp"
        from_port       = 3306
        to_port         = 3306
        cidr_blocks     = ["0.0.0.0/0"]
        security_groups = [aws_security_group.ecs_sg.id]
    }

    egress {
        from_port       = 0
        to_port         = 65535
        protocol        = "tcp"
        cidr_blocks     = ["0.0.0.0/0"]
    }
}

##################################
#Provision EC2 mysql tier instance
##################################

#get latest AMI builded by Packer
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["wordpress-mysql-tier-devops-cycloid-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["326719908831"] 
}

resource "aws_instance" "wordpress_mysql" {
  key_name      = aws_key_pair.ec2kepair.key_name
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  private_ip    = "10.0.0.151"

  tags = {
    Name = "mysql-tier-ec2"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("key")
    host        = self.public_ip
  }

  root_block_device {
    volume_size  = 8

  }

  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  subnet_id              = aws_subnet.pub_subnet.id
}

######################
#autoscaling group IAM
######################

data "aws_iam_policy_document" "ecs_agent" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_agent" {
  name               = "ecs-agent"
  assume_role_policy = data.aws_iam_policy_document.ecs_agent.json
}


resource "aws_iam_role_policy_attachment" "ecs_agent" {
  role       = aws_iam_role.ecs_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_agent" {
  name = "ecs-agent"
  role = aws_iam_role.ecs_agent.name
}

#get latest Amazon AMI
data "aws_ami" "ecs_ami" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-2.0.*-x86_64-ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["591542846629"] #Amazon
}

resource "aws_launch_configuration" "ecs_launch_config" {
    name                 = "ecs_launch_config"
    image_id             = data.aws_ami.ecs_ami.id
    iam_instance_profile = aws_iam_instance_profile.ecs_agent.name
    security_groups      = [aws_security_group.ecs_sg.id]
    user_data            = "#!/bin/bash\necho ECS_CLUSTER=ecs-wordpress-cluster >> /etc/ecs/ecs.config"
    instance_type        = "t2.micro"
}

resource "aws_autoscaling_group" "ecs_asg" {
    name                      = "ecs_asg"
    vpc_zone_identifier       = [aws_subnet.pub_subnet.id]
    launch_configuration      = aws_launch_configuration.ecs_launch_config.name

    desired_capacity          = 1
    min_size                  = 1
    max_size                  = 3
    health_check_grace_period = 300
    health_check_type         = "EC2"
}

#######################
#ECS cluster definition
#######################
resource "aws_ecs_cluster" "ecs_cluster" {
    name  = "ecs-wordpress-cluster"
}

########################
#Create taks definition 
########################
data "aws_ecs_task_definition" "wordpress" {
  task_definition = aws_ecs_task_definition.wordpress.family
}

resource "aws_ecs_task_definition" "wordpress" {
    family                   = "wordpress-test"
    requires_compatibilities = ["EC2"]
    memory                   = "512"
    network_mode             = "bridge"
    container_definitions    = <<DEFINITION
[
  {
    "name": "wordpress-devops-cycloid",
    "image": "docker.io/wordpress:latest",
    "essential": true,
    "portMappings": [
      {
        "containerPort": 80,
        "hostPort": 80
      }
    ],
    "memory": 512,
    "environment": [
                {
                    "name": "WORDPRESS_DB_HOST",
                    "value": "10.0.0.151:3306"
                },
                {
                    "name": "WORDPRESS_DB_USER",
                    "value": "wp_user"
                },
                {
                    "name": "WORDPRESS_DB_PASSWORD",
                    "value": "wp_password"
                },
                {
                    "name": "WORDPRESS_DB_NAME",
                    "value": "wordpress"
                }
            ]
  }
]
DEFINITION
}

###################
#Create ECS service
###################
resource "aws_ecs_service" "test-ecs-service" {
  	name            = "wp-ecs-service"
  	cluster         = aws_ecs_cluster.ecs_cluster.id
  	task_definition = aws_ecs_task_definition.wordpress.arn
    desired_count   = 1
}

