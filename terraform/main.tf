terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=5"
    }
  }
}

data "external" "env" {
  program = ["${path.module}/env.sh"]
}

provider "aws" {
  default_tags {
    tags = {
      Sandbox   = data.external.env.result.sandbox_name
      SandboxID = data.external.env.result.sandbox_id
      ManagedBy = "crafting-sandbox"
    }
  }
}

# --- Dedicated Host (persists across suspend/resume) ---

resource "aws_ec2_host" "mac" {
  instance_type     = var.instance_type
  availability_zone = var.availability_zone
  auto_placement    = "on"

  tags = {
    Name = "crafting-mac-${data.external.env.result.sandbox_name}"
  }
}

# --- Security Group ---
#
# NOTE: The example below opens SSH to 0.0.0.0/0 for simplicity. For production,
# lock ingress down to your Crafting cluster's egress CIDR (see the guide's
# "Security" section). The `cs mac` extension only needs workspace -> Mac:22,
# which originates from a Crafting egress IP, so an egress-only allowlist is
# sufficient and recommended.

resource "aws_security_group" "mac" {
  name_prefix = "crafting-mac-"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "crafting-mac-${data.external.env.result.sandbox_name}"
  }
}

# --- Mac Instance (terminated on suspend, re-created on resume) ---

resource "aws_instance" "mac" {
  count = var.suspended ? 0 : 1

  ami                    = var.ami_id
  instance_type          = var.instance_type
  host_id                = aws_ec2_host.mac.id
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.mac.id]

  root_block_device {
    volume_size = 200
    volume_type = "gp3"
  }

  user_data = <<-EOT
    #!/bin/bash
    # Inject the sandbox SSH public key for passwordless access
    mkdir -p /Users/ec2-user/.ssh
    echo "${data.external.env.result.ssh_pub}" >> /Users/ec2-user/.ssh/authorized_keys
    chmod 700 /Users/ec2-user/.ssh
    chmod 600 /Users/ec2-user/.ssh/authorized_keys
    chown -R ec2-user:staff /Users/ec2-user/.ssh
  EOT

  tags = {
    Name = "crafting-mac-${data.external.env.result.sandbox_name}"
  }
}

# --- Wait for SSH to become available ---

resource "null_resource" "wait_for_ssh" {
  count = var.suspended ? 0 : 1

  depends_on = [aws_instance.mac]

  provisioner "remote-exec" {
    connection {
      type    = "ssh"
      user    = "ec2-user"
      host    = aws_instance.mac[0].public_ip
      agent   = true
      timeout = "10m"
    }

    inline = ["echo 'SSH is ready'"]
  }
}
