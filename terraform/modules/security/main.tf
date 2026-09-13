locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Cluster   = var.cluster_name
    },
    var.additional_tags
  )
}

# ================================================================
# CONTROL PLANE SECURITY GROUP
# ================================================================

resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane"
  description = "Kubernetes control-plane security group"
  vpc_id      = var.vpc_id

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-control-plane"
      Role = "control-plane"
    }
  )
}

# Kubernetes API
resource "aws_vpc_security_group_ingress_rule" "control_plane_api_admin" {
  count = var.enable_public_api ? 1 : 0

  security_group_id = aws_security_group.control_plane.id

  cidr_ipv4   = var.admin_cidr
  from_port   = 6443
  to_port     = 6443
  ip_protocol = "tcp"

  description = "Kubernetes API access from administrator CIDR"
}

# etcd client
resource "aws_vpc_security_group_ingress_rule" "control_plane_etcd_client" {
  security_group_id = aws_security_group.control_plane.id

  referenced_security_group_id = aws_security_group.control_plane.id

  from_port   = 2379
  to_port     = 2379
  ip_protocol = "tcp"

  description = "etcd client traffic from control plane"
}

# etcd peer
resource "aws_vpc_security_group_ingress_rule" "control_plane_etcd_peer" {
  security_group_id = aws_security_group.control_plane.id

  referenced_security_group_id = aws_security_group.control_plane.id

  from_port   = 2380
  to_port     = 2380
  ip_protocol = "tcp"

  description = "etcd peer traffic between control-plane nodes"
}

# Kubelet from worker nodes
resource "aws_vpc_security_group_ingress_rule" "control_plane_kubelet_worker" {
  security_group_id = aws_security_group.control_plane.id

  referenced_security_group_id = aws_security_group.worker.id

  from_port   = 10250
  to_port     = 10250
  ip_protocol = "tcp"

  description = "Kubelet traffic from worker nodes"
}

# Kubernetes API from workers
resource "aws_vpc_security_group_ingress_rule" "control_plane_api_worker" {
  security_group_id = aws_security_group.control_plane.id

  referenced_security_group_id = aws_security_group.worker.id

  from_port   = 6443
  to_port     = 6443
  ip_protocol = "tcp"

  description = "Kubernetes API traffic from worker nodes"
}

# SSH
resource "aws_vpc_security_group_ingress_rule" "control_plane_ssh" {
  count = var.enable_ssh ? 1 : 0

  security_group_id = aws_security_group.control_plane.id

  cidr_ipv4   = var.admin_cidr
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"

  description = "SSH administrative access"
}

# HTTP
resource "aws_vpc_security_group_ingress_rule" "control_plane_http" {
  count = var.enable_http_https ? 1 : 0

  security_group_id = aws_security_group.control_plane.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"

  description = "HTTP traffic"
}

# HTTPS
resource "aws_vpc_security_group_ingress_rule" "control_plane_https" {
  count = var.enable_http_https ? 1 : 0

  security_group_id = aws_security_group.control_plane.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"

  description = "HTTPS traffic"
}

# NodePort
resource "aws_vpc_security_group_ingress_rule" "control_plane_nodeport" {
  count = var.enable_nodeport ? 1 : 0

  security_group_id = aws_security_group.control_plane.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 30000
  to_port     = 32767
  ip_protocol = "tcp"

  description = "Kubernetes NodePort TCP traffic"
}

resource "aws_vpc_security_group_egress_rule" "control_plane_all" {
  security_group_id = aws_security_group.control_plane.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  description = "Allow all outbound traffic"
}

# ================================================================
# WORKER SECURITY GROUP
# ================================================================

resource "aws_security_group" "worker" {
  name        = "${var.cluster_name}-worker"
  description = "Kubernetes worker-node security group"
  vpc_id      = var.vpc_id

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-worker"
      Role = "worker"
    }
  )
}

# Kubernetes API from workers
resource "aws_vpc_security_group_ingress_rule" "worker_api" {
  security_group_id = aws_security_group.worker.id

  referenced_security_group_id = aws_security_group.control_plane.id

  from_port   = 6443
  to_port     = 6443
  ip_protocol = "tcp"

  description = "Kubernetes API traffic from control plane"
}

# Kubelet from control plane
resource "aws_vpc_security_group_ingress_rule" "worker_kubelet_control_plane" {
  security_group_id = aws_security_group.worker.id

  referenced_security_group_id = aws_security_group.control_plane.id

  from_port   = 10250
  to_port     = 10250
  ip_protocol = "tcp"

  description = "Kubelet traffic from control plane"
}

# Kubelet between workers
resource "aws_vpc_security_group_ingress_rule" "worker_kubelet_workers" {
  security_group_id = aws_security_group.worker.id

  referenced_security_group_id = aws_security_group.worker.id

  from_port   = 10250
  to_port     = 10250
  ip_protocol = "tcp"

  description = "Kubelet traffic between worker nodes"
}

# Flannel VXLAN
resource "aws_vpc_security_group_ingress_rule" "worker_flannel" {
  security_group_id = aws_security_group.worker.id

  referenced_security_group_id = aws_security_group.worker.id

  from_port   = 8472
  to_port     = 8472
  ip_protocol = "udp"

  description = "Flannel VXLAN traffic between worker nodes"
}

# Worker-to-worker Kubernetes API
resource "aws_vpc_security_group_ingress_rule" "worker_api_workers" {
  security_group_id = aws_security_group.worker.id

  referenced_security_group_id = aws_security_group.worker.id

  from_port   = 6443
  to_port     = 6443
  ip_protocol = "tcp"

  description = "Kubernetes API traffic between worker nodes"
}

# SSH
resource "aws_vpc_security_group_ingress_rule" "worker_ssh" {
  count = var.enable_ssh ? 1 : 0

  security_group_id = aws_security_group.worker.id

  cidr_ipv4   = var.admin_cidr
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"

  description = "SSH administrative access"
}

# HTTP
resource "aws_vpc_security_group_ingress_rule" "worker_http" {
  count = var.enable_http_https ? 1 : 0

  security_group_id = aws_security_group.worker.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"

  description = "HTTP traffic"
}

# HTTPS
resource "aws_vpc_security_group_ingress_rule" "worker_https" {
  count = var.enable_http_https ? 1 : 0

  security_group_id = aws_security_group.worker.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"

  description = "HTTPS traffic"
}

# NodePort
resource "aws_vpc_security_group_ingress_rule" "worker_nodeport" {
  count = var.enable_nodeport ? 1 : 0

  security_group_id = aws_security_group.worker.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 30000
  to_port     = 32767
  ip_protocol = "tcp"

  description = "Kubernetes NodePort TCP traffic"
}

resource "aws_vpc_security_group_egress_rule" "worker_all" {
  security_group_id = aws_security_group.worker.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  description = "Allow all outbound traffic"
}
