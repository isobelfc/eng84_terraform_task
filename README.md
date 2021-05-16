# Terraform Task
Create a VPC, subnet, autoscaling group, and application load balancer using Terraform, and launch an instance with a running app

## Variables file
- Create a file called `variable.tf` to store variables in an organised way
- Define each variable you plan to use like so:
```
variable "name" {
    default = "eng84_isobel_terraform"
}

variable "aws_key_name" {
    default = "eng84devops"
}
```
- AMI IDs, key names and paths, and the ID of any pre-existing VPC or subnet that you plan to use are useful things to define as variables

### Referencing variables
- To reference the variable later, use `var.variable_name`, e.g. `var.aws_key_name`

## Main file
- Create a file called `main.tf`
- This is where the code to create each AWS feature will be contained
- Blocks of code start with a keyword, such as `provider`, `resource`, or `data`
- They then state what the block will be defining. Most of our block definitions will start with `aws_`
- We then give it a name for our own personal reference, to distinguish it from any other blocks of the same feature
- Within `{}` we list our arguments for the block

### Define provider
- Terraform can be used with a number of different cloud providers, so we need to tell it we are using AWS, and in which region (here, `eu-west-1`)
```
provider "aws" {
    region = var.region
}
```

### Create VPC
- We need a VPC to contain all our other modules
- It needs to have a CIDR block, and should have a name so that we can find it easily
```
resource "aws_vpc" "vpc" {
    cidr_block = "10.0.0.0/16"

    instance_tenancy = "default"

    tags = {
        Name = "${var.name}_vpc"
    }
}
```

### Create Subnets
- We now create 2 different subnets
- They need to have a CIDR block within that of the VPC
```
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
```
- As well as referencing values from our variables file, we can refer to properties of other modules created within this file
- `aws_vpc.vpc.id` gets the ID of the VPC defined above with `aws_vpc` and given the name `vpc`

### Create Internet Gateway
- We need an internet gateway if our instances are to access the internet
```
resource "aws_internet_gateway" "internet_gateway" {
    vpc_id = aws_vpc.vpc.id
    tags = {
        Name = "${var.name}_ig"
    }
}
```

### Create route table
- A route table will allow our subnets access to our internet gateway, once they are associated
```
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
```

### Associate route table with subnets
- We need to create route table associations to finalise the internet connection
```
resource "aws_route_table_association" "rt_association_1" {
  subnet_id = aws_subnet.subnet_1.id
  route_table_id = aws_route_table.route_table.id
}


resource "aws_route_table_association" "rt_association_2" {
  subnet_id = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.route_table.id
}
```

### Create security groups
- Our app security group allows inbound traffic on Port 80, to allow it to launch in the browser
- It allows all outbound traffic, using the `-1` protocol
```
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
```

- Our database security group allows access on Port 27017, to connect to Mongodb, from the app security group
```
resource "aws_security_group" "db_sg" {
    name = "${var.name}_db_sg"
    description = "db group"
    vpc_id = aws_vpc.vpc.id

    # inbound rules
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
```

### Create database instance
- We use an AMI image to launch our instance from
- We also give it a name, and define the key, security group, and subnet of the instance
```
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
```

### Create app launch template
- To launch our app within an autoscaling group, we need to use a launch template
- This is again based on an AMI, and states the key, security group, and subnet we will use
- `user_data` is used to provide a script which will run when the instance is launched (see section below)
```
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

    user_data = base64encode(file("./deployment.tpl"))
}
```

### Create a load balancer
- We want to use an application load balancer with this app
- Load balancers do not allow underscores in the name, so we cannot use the name variable we defined earlier
```
resource "aws_lb" "lb" {
    name = "eng84-isobel-terraform-lb"
    internal = false
    load_balancer_type = "application"
    security_groups = [aws_security_group.app_sg.id]
    subnets = [aws_subnet.subnet_1.id, aws_subnet.subnet_2.id]
}
```
- Next we create a target group for the load balancer, which we will need in order to link it to the autoscaling group
```
resource "aws_lb_target_group" "lb_tg" {
    name = "eng84-isobel-tf-target-group"
    port = 80
    protocol = "HTTP"
    vpc_id = aws_vpc.vpc.id
}
```
- Finally, we create a listener for the load balancer
```
resource "aws_lb_listener" "lb_listener" {
    load_balancer_arn = aws_lb.lb.arn
    port = "80"
    protocol = "HTTP"
    default_action {
        type = "forward"
        target_group_arn = aws_lb_target_group.lb_tg.arn
    }
}
```

### Create an autoscaling group
- The last thing we need to define within our main file is our autoscaling group
- We give it the number of instance we want it to contain, and it will keep the number within those levels
- We attach the load balancer, and give it the launch template for our app
```
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
```

## Deployment file
- Earlier, we gave our app launch template a file to run each time an instance launches
- Create a file called `deployment.tpl`
- On the first line of the file, put `#!/bin/bash` to tell the interpreter that this is a bash file
- Then list each of the commands to run, as you would enter them in the terminal
- Here, we run `npm install` and then seed our database from the `seed.js` file, and finally launch our app with `pm2 start app.js`
- The app will now run every time an app instance is created, without having to SSH into it
```
#!/bin/bash
cd home/ubuntu/eng84_cicd_jenkins/app
npm install
pm2 kill
nodejs seeds/seed.js
pm2 start app.js
```

## Run the Terraform files
- Use `terraform init` in the terminal while in the directory containing the files to initialise Terraform
- Use `terraform plan` to see what tasks will be carried out if you run the files. Any errors will be flagged up at this point
- Use `terraform apply` to run the scripts and type `yes` to confirm when prompted
- Everything contained within the files will now be created and you can check it within the AWS console
