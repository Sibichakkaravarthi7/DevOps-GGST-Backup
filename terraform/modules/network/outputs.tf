output "vpc_id" {
  description = "VPC ID used by the Kubernetes cluster"
  value = var.network_mode == "managed" ? (
    aws_vpc.this[0].id
  ) : data.aws_vpc.existing[0].id
}

output "vpc_cidr" {
  description = "VPC CIDR"
  value = var.network_mode == "managed" ? (
    aws_vpc.this[0].cidr_block
  ) : data.aws_vpc.existing[0].cidr_block
}

output "control_plane_subnet_id" {
  description = "Control-plane subnet ID"
  value = var.network_mode == "managed" ? (
    aws_subnet.control_plane[0].id
  ) : data.aws_subnet.existing_control_plane[0].id
}

output "worker_subnet_ids" {
  description = "Worker subnet IDs"
  value = var.network_mode == "managed" ? (
    aws_subnet.workers[*].id
  ) : sort(keys(data.aws_subnet.existing_workers))
}

output "control_plane_subnet_az" {
  description = "Availability Zone of the control-plane subnet"
  value = var.network_mode == "managed" ? (
    aws_subnet.control_plane[0].availability_zone
  ) : data.aws_subnet.existing_control_plane[0].availability_zone
}
