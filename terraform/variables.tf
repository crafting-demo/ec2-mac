variable "instance_type" {
  description = "EC2 Mac instance type"
  default     = "mac2.metal"
}

variable "ami_id" {
  description = "macOS AMI ID (use a custom AMI with Xcode pre-installed for faster startup)"
  type        = string
}

variable "availability_zone" {
  description = "AZ that supports Mac instances"
  type        = string
}

variable "vpc_id" {
  description = "VPC to launch the instance in"
  type        = string
}

variable "subnet_id" {
  description = "Subnet in the target AZ"
  type        = string
}

variable "ssh_ingress_cidrs" {
  description = "CIDRs allowed to reach the Mac on TCP 22. Set this to your Crafting cluster egress CIDR."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "data_volume_size" {
  description = "Size in GiB of the persistent EBS data volume that holds the synced repo and DerivedData"
  type        = number
  default     = 200
}

variable "suspended" {
  description = "Deprecated and ignored: the instance now keeps running through suspend. Kept so templates that still pass -var suspended=true don't fail."
  type        = bool
  default     = false
}
