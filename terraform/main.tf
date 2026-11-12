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

# --- Dedicated Host (lives until the sandbox is deleted) ---

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
# NOTE: `ssh_ingress_cidrs` defaults to 0.0.0.0/0 for simplicity. For production,
# set it to your Crafting cluster's egress CIDR (see the guide's "Security"
# section). The Mac keeps running while the sandbox is suspended, so it stays
# reachable even when nobody is using it. The `cs mac` extension and the
# workspace sync only need workspace -> Mac:22, which originates from a Crafting
# egress IP, so an egress-only allowlist is sufficient and recommended.

resource "aws_security_group" "mac" {
  name_prefix = "crafting-mac-"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_ingress_cidrs
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

# --- Mac Instance (kept running through suspend/resume) ---
#
# Stopping or terminating a Mac instance triggers a scrub of the Dedicated Host,
# and the instance itself is free on a Dedicated Host, so the instance stays up
# for the life of the sandbox.

resource "aws_instance" "mac" {
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

  # Destroy the instance before the data volume: the volume can't be deleted
  # while it's still attached to a terminating instance.
  depends_on = [aws_ebs_volume.data]

  lifecycle {
    # Updating user_data in place stops and restarts the instance, which
    # triggers a host scrub. It only matters on first boot anyway.
    ignore_changes = [user_data]
  }
}

# --- Persistent data volume (repo + DerivedData) ---
#
# Separate from the instance so it survives instance replacement (e.g. an AMI
# change). Destroyed with the rest of the sandbox on delete.

resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size
  type              = "gp3"

  tags = {
    Name = "crafting-mac-data-${data.external.env.result.sandbox_name}"
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.mac.id

  # Don't force-detach a mounted APFS volume from a running Mac. Terminating the
  # instance releases the volume on its own.
  skip_destroy = true
}

# --- Wait for SSH to become available ---

resource "null_resource" "wait_for_ssh" {
  depends_on = [aws_instance.mac]

  provisioner "remote-exec" {
    connection {
      type    = "ssh"
      user    = "ec2-user"
      host    = aws_instance.mac.public_ip
      agent   = true
      timeout = "10m"
    }

    inline = ["echo 'SSH is ready'"]
  }
}
