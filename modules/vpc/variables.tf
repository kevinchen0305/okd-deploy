variable "cluster_name" {
  description = "Name of the OKD cluster. Used in resource naming and the kubernetes.io/cluster/<name> tag."
  type        = string
}

variable "region" {
  description = "AWS region the VPC is deployed into."
  type        = string
}

variable "az" {
  description = "Single Availability Zone used for both subnets and the NAT Gateway."
  type        = string
}

variable "cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet."
  type        = string
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet."
  type        = string
  default     = "10.0.16.0/20"
}

variable "tags" {
  description = "Extra tags merged into all resources created by this module."
  type        = map(string)
  default     = {}
}
