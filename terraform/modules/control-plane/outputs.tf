output "instance_id" {
  description = "Control-plane EC2 instance ID"
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "Control-plane private IP"
  value       = aws_instance.this.private_ip
}

output "public_ip" {
  description = "Control-plane public IP"
  value       = aws_instance.this.public_ip
}

output "private_dns" {
  description = "Control-plane private DNS"
  value       = aws_instance.this.private_dns
}

output "availability_zone" {
  description = "Control-plane Availability Zone"
  value       = aws_instance.this.availability_zone
}
