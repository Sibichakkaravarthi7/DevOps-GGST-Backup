variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
}

variable "ssm_join_parameter" {
  description = "SSM parameter containing the kubeadm worker join command"
  type        = string
}

variable "additional_tags" {
  description = "Additional IAM resource tags"
  type        = map(string)
  default     = {}
}
