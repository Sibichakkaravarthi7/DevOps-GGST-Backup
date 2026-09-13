output "control_plane_role_name" {
  description = "Control-plane IAM role name"
  value       = aws_iam_role.control_plane.name
}

output "control_plane_role_arn" {
  description = "Control-plane IAM role ARN"
  value       = aws_iam_role.control_plane.arn
}

output "control_plane_instance_profile_name" {
  description = "Control-plane EC2 instance profile name"
  value       = aws_iam_instance_profile.control_plane.name
}

output "worker_role_name" {
  description = "Worker IAM role name"
  value       = aws_iam_role.worker.name
}

output "worker_role_arn" {
  description = "Worker IAM role ARN"
  value       = aws_iam_role.worker.arn
}

output "worker_instance_profile_name" {
  description = "Worker EC2 instance profile name"
  value       = aws_iam_instance_profile.worker.name
}
