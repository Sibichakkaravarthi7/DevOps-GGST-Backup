output "vpc_id" {
  description = "VPC ID used by the Kubernetes cluster"
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR"
  value       = module.network.vpc_cidr
}

output "control_plane_subnet_id" {
  description = "Control-plane subnet ID"
  value       = module.network.control_plane_subnet_id
}

output "worker_subnet_ids" {
  description = "Worker subnet IDs"
  value       = module.network.worker_subnet_ids
}

output "control_plane_subnet_az" {
  description = "Control-plane subnet Availability Zone"
  value       = module.network.control_plane_subnet_az
}

output "control_plane_role_name" {
  description = "Control-plane IAM role"
  value       = module.iam.control_plane_role_name
}

output "control_plane_instance_profile_name" {
  description = "Control-plane EC2 instance profile"
  value       = module.iam.control_plane_instance_profile_name
}

output "worker_role_name" {
  description = "Worker IAM role"
  value       = module.iam.worker_role_name
}

output "worker_instance_profile_name" {
  description = "Worker EC2 instance profile"
  value       = module.iam.worker_instance_profile_name
}

output "control_plane_security_group_id" {
  description = "Control-plane security group"
  value       = module.security.control_plane_security_group_id
}

output "worker_security_group_id" {
  description = "Worker security group"
  value       = module.security.worker_security_group_id
}

output "control_plane_instance_id" {
  description = "Control-plane EC2 instance ID"
  value       = module.control_plane.instance_id
}

output "control_plane_private_ip" {
  description = "Control-plane private IP"
  value       = module.control_plane.private_ip
}

output "control_plane_public_ip" {
  description = "Control-plane public IP"
  value       = module.control_plane.public_ip
}

output "control_plane_availability_zone" {
  description = "Control-plane Availability Zone"
  value       = module.control_plane.availability_zone
}

output "worker_launch_template_id" {
  description = "Worker launch template ID"
  value       = module.worker_asg.launch_template_id
}

output "worker_launch_template_name" {
  description = "Worker launch template name"
  value       = module.worker_asg.launch_template_name
}

output "worker_launch_template_latest_version" {
  description = "Worker launch template latest version"
  value       = module.worker_asg.launch_template_latest_version
}

output "worker_autoscaling_group_name" {
  description = "Worker Auto Scaling Group name"
  value       = module.worker_asg.autoscaling_group_name
}

output "worker_autoscaling_group_arn" {
  description = "Worker Auto Scaling Group ARN"
  value       = module.worker_asg.autoscaling_group_arn
}
