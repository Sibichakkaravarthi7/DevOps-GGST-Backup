output "launch_template_id" {
  description = "Worker launch template ID"
  value       = aws_launch_template.this.id
}

output "launch_template_name" {
  description = "Worker launch template name"
  value       = aws_launch_template.this.name
}

output "launch_template_latest_version" {
  description = "Latest worker launch template version"
  value       = aws_launch_template.this.latest_version
}

output "autoscaling_group_name" {
  description = "Worker Auto Scaling Group name"
  value       = aws_autoscaling_group.this.name
}

output "autoscaling_group_arn" {
  description = "Worker Auto Scaling Group ARN"
  value       = aws_autoscaling_group.this.arn
}

output "min_size" {
  description = "Worker ASG minimum size"
  value       = aws_autoscaling_group.this.min_size
}

output "desired_size" {
  description = "Worker ASG desired size"
  value       = aws_autoscaling_group.this.desired_capacity
}

output "max_size" {
  description = "Worker ASG maximum size"
  value       = aws_autoscaling_group.this.max_size
}
