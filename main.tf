# Initialise terraform

# This code will eventually launch an EC2 instance for us
# var.name_of_resource loads a variable from variable.tf

# provider is a keyword in Terraform to define the name of cloud provider

provider "aws" {
    region = var.region
}


# resource is a keyword


resource "aws_vpc" "vpc" {
    cidr_block = "10.0.0.0/16"

    instance_tenancy = "default"

    tags = {
        Name = "${var.name}_vpc"
    }
}


resource "aws_subnet" "subnet_1" {
    vpc_id = aws_vpc.vpc.id
    cidr_block = "10.0.1.0/24"
    availability_zone = "eu-west-1a"

    tags = {
        Name = "${var.name}_subnet_1"
    }
}


resource "aws_subnet" "subnet_2" {
    vpc_id = aws_vpc.vpc.id
    cidr_block = "10.0.2.0/24"
    availability_zone = "eu-west-1b"

    tags = {
        Name = "${var.name}_subnet_2"
    }
}


resource "aws_internet_gateway" "internet_gateway" {
    vpc_id = aws_vpc.vpc.id
    tags = {
        Name = "${var.name}_ig"
    }
}


resource "aws_route_table" "route_table" {
    vpc_id = aws_vpc.vpc.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.internet_gateway.id
    }

    tags = {
        Name = "${var.name}_rt"
    }
}


resource "aws_route_table_association" "rt_association_1" {
  subnet_id = aws_subnet.subnet_1.id
  route_table_id = aws_route_table.route_table.id
}


resource "aws_route_table_association" "rt_association_2" {
  subnet_id = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.route_table.id
}


resource "aws_security_group" "app_sg" {
    name = "${var.name}_app_sg"
    description = "app group"
    vpc_id = aws_vpc.vpc.id

    # inbound rules
    ingress {
        from_port = "80"  # to launch in the browser
        to_port = "80"
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]  # allow all
    }

    ingress {
        from_port = "22"  # to ssh into
        to_port = "22"
        protocol = "tcp"
        cidr_blocks = ["${var.my_ip}"]  # from my ip only
    }

    # outbound rules
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"  # allow all
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Name = "${var.name}_app_sg"
    }
}


resource "aws_security_group" "db_sg" {
    name = "${var.name}_db_sg"
    description = "db group"
    vpc_id = aws_vpc.vpc.id

    # inbound rules
    ingress {
        from_port = "80"
        to_port = "80"
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]  # allow all
    }

    ingress {
        from_port = "27017"  # database access
        to_port = "27017"
        protocol = "tcp"
        security_groups = [aws_security_group.app_sg.id]  # from app instances
    }

    # outbound rules
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"  # allow all
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Name = "${var.name}_db_sg"
    }
}


# # 1st iteration - create instance from ami
# resource "aws_instance" "app_instance" {
#     # add AMI id
#     ami = var.webapp_ami_id
#
#     # add the type of instance
#     instance_type = "t2.micro"
#
#     # do we enable public IP for app?
#     associate_public_ip_address = true
#
#     # tags to give name to our instance
#     tags = {
#         Name = "${var.name}"
#     }
#
#     # set key to use
#     key_name = "${var.aws_key_name}"
#
#     # add security groups
#     vpc_security_group_ids = ["${aws_security_group.app_sg.id}"]
#
#     # set subnet - add this line after creation of subnet
#     subnet_id = aws_subnet.subnet_1.id
#
#     # provisioner "file" {
#     #   source      = "./scripts/app/init.sh.tpl"
#     #   destination = "/etc"
#     # }
#
# }


# db instance, not in asg
resource "aws_instance" "db_instance" {
    ami = var.db_ami_id
    instance_type = "t2.micro"
    associate_public_ip_address = true
    private_ip = "10.0.1.139"

    tags = {
        Name = "${var.name}_db"
    }

    key_name = "${var.aws_key_name}"
    vpc_security_group_ids = ["${aws_security_group.db_sg.id}"]
    subnet_id = aws_subnet.subnet_1.id
}


# 2nd iteration - use launch template in autoscaling group
resource "aws_launch_template" "app_template" {
    image_id = var.webapp_ami_id
    instance_type = "t2.micro"
    key_name = var.aws_key_name

    network_interfaces {
        associate_public_ip_address = true
        security_groups = [aws_security_group.app_sg.id]
        subnet_id = aws_subnet.subnet_1.id
    }

    tag_specifications {
        resource_type = "instance"
        tags = {
            Name = "${var.name}_app"
        }
    }

    # user_data = base64encode(templatefile("./deployment.tpl", {db_private_ip = "${aws_instance.db_instance.private_ip}"}))
    user_data = base64encode(file("./deployment.tpl"))
}


# load balancer target group
resource "aws_lb_target_group" "lb_tg" {
    name = "eng84-isobel-tf-target-group"
    port = 80
    protocol = "HTTP"
    vpc_id = aws_vpc.vpc.id
}


# load balancer
resource "aws_lb" "lb" {
    name = "eng84-isobel-terraform-lb"
    internal = false
    load_balancer_type = "application"
    security_groups = [aws_security_group.app_sg.id]
    subnets = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id]
}


resource "aws_lb_listener" "lb_listener" {
    load_balancer_arn = aws_lb.lb.arn
    port = "80"
    protocol = "HTTP"
    default_action {
        type = "forward"
        target_group_arn = aws_lb_target_group.lb_tg.arn
    }
}


resource "aws_autoscaling_group" "asg" {
    name = "${var.name}_asg"
    availability_zones = ["${var.region}a"]
    desired_capacity = 2
    max_size = 2
    min_size = 2
    target_group_arns = [aws_lb_target_group.lb_tg.arn]  # attach load balancer

    launch_template {
        id = aws_launch_template.app_template.id
        version = "$Latest"
    }
}
