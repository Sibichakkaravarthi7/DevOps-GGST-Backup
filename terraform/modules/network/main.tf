data "aws_region" "current" {}

locals {
  managed = var.network_mode == "managed"

  common_tags = merge(
    {
      ManagedBy = "terraform"
    },
    var.additional_tags
  )

  worker_azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(
    data.aws_availability_zones.available.names,
    0,
    min(length(var.worker_subnet_cidrs), length(data.aws_availability_zones.available.names))
  )
}

data "aws_availability_zones" "available" {
  state = "available"
}

# -------------------------------------------------------------------
# EXISTING VPC
# -------------------------------------------------------------------

data "aws_vpc" "existing" {
  count = var.network_mode == "existing" ? 1 : 0
  id    = var.vpc_id
}

data "aws_subnet" "existing_control_plane" {
  count = var.network_mode == "existing" && var.control_plane_subnet_id != null ? 1 : 0
  id    = var.control_plane_subnet_id
}

data "aws_subnet" "existing_workers" {
  for_each = var.network_mode == "existing" ? toset(var.worker_subnet_ids) : toset([])
  id       = each.value
}

# -------------------------------------------------------------------
# MANAGED VPC
# -------------------------------------------------------------------

resource "aws_vpc" "this" {
  count = local.managed ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(
    local.common_tags,
    {
      Name = "k8s-vpc"
    }
  )
}

resource "aws_internet_gateway" "this" {
  count = local.managed ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(
    local.common_tags,
    {
      Name = "k8s-igw"
    }
  )
}

resource "aws_subnet" "control_plane" {
  count = local.managed ? 1 : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = var.control_plane_subnet_cidr
  availability_zone       = local.worker_azs[0]
  map_public_ip_on_launch = true

  tags = merge(
    local.common_tags,
    {
      Name = "k8s-control-plane-subnet"
    }
  )
}

resource "aws_subnet" "workers" {
  count = local.managed ? length(var.worker_subnet_cidrs) : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = var.worker_subnet_cidrs[count.index]
  availability_zone       = local.worker_azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(
    local.common_tags,
    {
      Name = "k8s-worker-subnet-${count.index + 1}"
    }
  )
}

resource "aws_route_table" "public" {
  count = local.managed ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = merge(
    local.common_tags,
    {
      Name = "k8s-public-rt"
    }
  )
}

resource "aws_route_table_association" "control_plane" {
  count = local.managed ? 1 : 0

  subnet_id      = aws_subnet.control_plane[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "workers" {
  count = local.managed ? length(aws_subnet.workers) : 0

  subnet_id      = aws_subnet.workers[count.index].id
  route_table_id = aws_route_table.public[0].id
}
