output "control_plane_security_group_id" {
  description = "Control-plane security group ID"
  value       = aws_security_group.control_plane.id
}

output "control_plane_security_group_name" {
  description = "Control-plane security group name"
  value       = aws_security_group.control_plane.name
}

output "worker_security_group_id" {
  description = "Worker security group ID"
  value       = aws_security_group.worker.id
}

output "worker_security_group_name" {
  description = "Worker security group name"
  value       = aws_security_group.worker.name
}
