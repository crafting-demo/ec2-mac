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

variable "suspended" {
  description = "When true, the instance is terminated but the Dedicated Host persists"
  type        = bool
  default     = false
}
