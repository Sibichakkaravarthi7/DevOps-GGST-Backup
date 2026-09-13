variable "network_mode" {
  description = "Whether to use an existing VPC or create a managed VPC"
  type        = string

  validation {
    condition     = contains(["existing", "managed"], var.network_mode)
    error_message = "network_mode must be either 'existing' or 'managed'."
  }
}

variable "vpc_id" {
  description = "Existing VPC ID when network_mode is existing"
  type        = string
  default     = null
}

variable "control_plane_subnet_id" {
  description = "Existing subnet ID for the control-plane node"
  type        = string
  default     = null
}

variable "worker_subnet_ids" {
  description = "Existing subnet IDs for worker nodes"
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR for a managed VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for managed worker subnets"
  type        = list(string)
  default     = []
}

variable "control_plane_subnet_cidr" {
  description = "CIDR for the managed control-plane subnet"
  type        = string
  default     = "10.20.0.0/20"
}

variable "worker_subnet_cidrs" {
  description = "CIDRs for managed worker subnets"
  type        = list(string)
  default     = [
    "10.20.16.0/20",
    "10.20.32.0/20",
    "10.20.48.0/20"
  ]
}

variable "enable_nat_gateway" {
  description = "Whether managed worker subnets should use a NAT Gateway"
  type        = bool
  default     = false
}

variable "additional_tags" {
  description = "Additional AWS resource tags"
  type        = map(string)
  default     = {}
}
