variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
}

variable "ami_id" {
  description = "Ubuntu AMI ID for worker nodes"
  type        = string
}

variable "instance_type" {
  description = "Worker EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "subnet_ids" {
  description = "Worker subnet IDs"
  type        = list(string)
}

variable "security_group_id" {
  description = "Worker security group ID"
  type        = string
}

variable "instance_profile_name" {
  description = "Worker IAM instance profile"
  type        = string
}

variable "key_name" {
  description = "Existing EC2 key pair name"
  type        = string
}

variable "min_size" {
  description = "Minimum worker nodes"
  type        = number
  default     = 1
}

variable "desired_size" {
  description = "Desired worker nodes"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum worker nodes"
  type        = number
  default     = 5
}

variable "root_volume_size" {
  description = "Worker root EBS volume size in GiB"
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Worker root EBS volume type"
  type        = string
  default     = "gp3"
}

variable "user_data" {
  description = "Worker bootstrap user data"
  type        = string
  default     = null
}

variable "additional_tags" {
  description = "Additional worker ASG tags"
  type        = map(string)
  default     = {}
}
