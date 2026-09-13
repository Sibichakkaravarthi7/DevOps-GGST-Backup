variable "project_name" {
  description = "Project name"
  type        = string
  default     = "aws-k8s-platform"
}

variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_name)) && length(var.cluster_name) <= 40
    error_message = "cluster_name must contain only lowercase letters, numbers, and hyphens, and be <= 40 characters."
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "network_mode" {
  description = "Use an existing VPC or create a managed VPC"
  type        = string
  default     = "existing"

  validation {
    condition     = contains(["existing", "managed"], var.network_mode)
    error_message = "network_mode must be either existing or managed."
  }
}

variable "vpc_id" {
  description = "Existing VPC ID"
  type        = string
  default     = null
}

variable "control_plane_subnet_id" {
  description = "Existing control-plane subnet ID"
  type        = string
  default     = null
}

variable "worker_subnet_ids" {
  description = "Existing worker subnet IDs"
  type        = list(string)
  default     = []
}

variable "pod_cidr" {
  description = "Kubernetes pod CIDR"
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes service CIDR"
  type        = string
  default     = "10.96.0.0/12"
}

variable "ami_id" {
  description = "Ubuntu AMI ID used by control-plane and worker instances"
  type        = string
  default     = null
}

variable "control_plane_instance_type" {
  description = "Control-plane EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "Worker EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Existing AWS EC2 key pair name"
  type        = string
  default     = null
}

variable "worker_min_size" {
  description = "Worker ASG minimum size"
  type        = number
  default     = 1
}

variable "worker_desired_size" {
  description = "Worker ASG desired size"
  type        = number
  default     = 1
}

variable "worker_max_size" {
  description = "Worker ASG maximum size"
  type        = number
  default     = 5
}

variable "kubernetes_version" {
  description = "Full Kubernetes version"
  type        = string
  default     = "1.30.14"
}

variable "kubernetes_minor_version" {
  description = "Kubernetes package repository minor version"
  type        = string
  default     = "1.30"
}

variable "ssm_join_parameter" {
  description = "SSM SecureString parameter containing kubeadm join command"
  type        = string
  default     = "/k8s/join-command"
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

variable "admin_cidr" {
  description = "CIDR allowed for administrative Kubernetes API and SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "enable_ssh" {
  description = "Enable SSH access to Kubernetes nodes"
  type        = bool
  default     = true
}

variable "enable_public_api" {
  description = "Allow Kubernetes API access from admin_cidr"
  type        = bool
  default     = true
}

variable "enable_nodeport" {
  description = "Allow public Kubernetes NodePort traffic"
  type        = bool
  default     = false
}

variable "enable_http_https" {
  description = "Allow public HTTP and HTTPS traffic"
  type        = bool
  default     = false
}

variable "additional_tags" {
  description = "Additional AWS tags"
  type        = map(string)
  default     = {}
}
