variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
}

variable "ami_id" {
  description = "Ubuntu AMI ID"
  type        = string
}

variable "instance_type" {
  description = "Control-plane EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "subnet_id" {
  description = "Control-plane subnet ID"
  type        = string
}

variable "security_group_id" {
  description = "Control-plane security group ID"
  type        = string
}

variable "instance_profile_name" {
  description = "Control-plane IAM instance profile"
  type        = string
}

variable "key_name" {
  description = "Existing EC2 key pair name"
  type        = string
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Root EBS volume type"
  type        = string
  default     = "gp3"
}

variable "user_data" {
  description = "Optional EC2 user data"
  type        = string
  default     = null
}

variable "additional_tags" {
  description = "Additional EC2 tags"
  type        = map(string)
  default     = {}
}
