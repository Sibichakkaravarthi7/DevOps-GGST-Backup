variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the Kubernetes cluster will run"
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed to access the Kubernetes API and SSH"
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be a valid CIDR."
  }
}

variable "enable_ssh" {
  description = "Allow SSH access to Kubernetes nodes"
  type        = bool
  default     = true
}

variable "enable_public_api" {
  description = "Allow Kubernetes API access from admin_cidr"
  type        = bool
  default     = true
}

variable "enable_nodeport" {
  description = "Allow Kubernetes NodePort traffic from the Internet"
  type        = bool
  default     = false
}

variable "enable_http_https" {
  description = "Allow HTTP and HTTPS traffic to nodes"
  type        = bool
  default     = false
}

variable "additional_tags" {
  description = "Additional security group tags"
  type        = map(string)
  default     = {}
}
