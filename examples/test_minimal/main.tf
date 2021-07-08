locals {
  az = "${data.aws_region.current.name}a"
  private_subnets = ["172.20.0.0/24"]
  public_subnets  = ["172.20.3.0/24"]

  tamr_vm_s3_actions = [
    "s3:PutObject",
    "s3:GetObject",
    "s3:DeleteObject",
    "s3:AbortMultipartUpload",
    "s3:ListBucket",
    "s3:ListObjects",
    "s3:CreateJob",
    "s3:HeadBucket"
  ]
}

data "aws_region" "current" { }

provider "aws" {

}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.1.0"

  name = "${var.name-prefix}-test-vpc"
  cidr = "172.20.0.0/18"

  azs             = [local.az]
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway = false
  enable_vpn_gateway = false

  tags = {
    Terraform = "true"
    Terratest = "true"
    Environment = "dev"
  }
}

# Set up HBase logs bucket
module "s3-bucket" {
  source             = "git::git@github.com:Datatamer/terraform-aws-s3.git?ref=1.0.0"
  bucket_name        = format("%s-tamr-module-test-bucket", var.name-prefix)
  read_write_actions = local.tamr_vm_s3_actions
  read_write_paths   = ["*"] # r/w policy permitting specified rw actions on entire bucket
}

# Upload bootstrap scripts to S3
resource "aws_s3_bucket_object" "install_pip_bootstrap_script" {
  bucket                 = module.s3-bucket.bucket_name
  key                    = "bootstrap-script-tamr-vm/install-pip.sh"
  source                 = "../minimal/test-bootstrap-scripts/install-pip.sh"
  content_type           = "text/x-shellscript"
  server_side_encryption = "AES256"
}

resource "aws_s3_bucket_object" "check_pip_install_script" {
  bucket                 = module.s3-bucket.bucket_name
  key                    = "bootstrap-script-tamr-vm/check-install.sh"
  source                 = "../minimal/test-bootstrap-scripts/check-install.sh"
  content_type           = "text/x-shellscript"
  server_side_encryption = "AES256"
}

# Retrieve content of bootstrap script S3 objects
data "aws_s3_bucket_object" "bootstrap_script" {
  bucket = module.s3-bucket.bucket_name
  key    = aws_s3_bucket_object.install_pip_bootstrap_script.id
}

data "aws_s3_bucket_object" "bootstrap_script_2" {
  bucket = module.s3-bucket.bucket_name
  key    = aws_s3_bucket_object.check_pip_install_script.id
}

# Create new EC2 key pair
resource "tls_private_key" "tamr_ec2_private_key" {
  algorithm = "RSA"
}

module "tamr_ec2_key_pair" {
  source     = "terraform-aws-modules/key-pair/aws"
  version    = "1.0.0"
  key_name   = format("%s-tamr-ec2-test-key", var.name-prefix)
  public_key = tls_private_key.tamr_ec2_private_key.public_key_openssh
}

module "aws-vm-sg-ports" {
  #source = "git::https://github.com/Datatamer/terraform-aws-tamr-vm.git//modules/aws-security-groups?ref=2.0.0"
  source = "../../modules/aws-security-groups"
}

module "aws-sg" {
  source = "git::git@github.com:Datatamer/terraform-aws-security-groups.git?ref=0.1.0"
  vpc_id = module.vpc.vpc_id
  ingress_cidr_blocks = [
    "1.2.3.0/24"
  ]
  egress_cidr_blocks = [
    "0.0.0.0/0"
  ]
  ingress_ports  = module.aws-vm-sg-ports.ingress_ports
  sg_name_prefix = var.name-prefix
}

module "tamr-vm" {
  # source                           = "git::git@github.com:Datatamer/terraform-aws-tamr-vm.git?ref=3.0.0"
  source                      = "../.."
  aws_role_name               = format("%s-tamr-ec2-role", var.name-prefix)
  aws_instance_profile_name   = format("%s-tamr-ec2-instance-profile", var.name-prefix)
  aws_emr_creator_policy_name = format("%sEmrCreatorPolicy", var.name-prefix)
  s3_policy_arns = [
    module.s3-bucket.rw_policy_arn,
  ]
  ami               = data.aws_ami.ubuntu.id
  instance_type     = "m4.large"
  key_name          = module.tamr_ec2_key_pair.key_pair_key_name
  availability_zone = local.az
  vpc_id            = module.vpc.vpc_id
  subnet_id         = module.vpc.private_subnets[0]
  bootstrap_scripts = [
    # NOTE: If you would like to use local scripts, you can use terraform's file() function
    # file("./test-bootstrap-scripts/install-pip.sh"),
    # file("./test-bootstrap-scripts/check-install.sh"),
    data.aws_s3_bucket_object.bootstrap_script.body,
    data.aws_s3_bucket_object.bootstrap_script_2.body
  ]

  security_group_ids = module.aws-sg.security_group_ids
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "image-type"
    values = ["machine"]
  }

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }
}