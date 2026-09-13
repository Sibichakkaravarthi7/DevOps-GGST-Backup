locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Cluster   = var.cluster_name
      Role      = "control-plane"

      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    },
    var.additional_tags
  )
}

resource "aws_instance" "this" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids     = [var.security_group_id]
  iam_instance_profile        = var.instance_profile_name
  key_name                    = var.key_name
  user_data                   = var.user_data
  user_data_replace_on_change = true

  associate_public_ip_address = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    delete_on_termination = true
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-control-plane"
    }
  )
}
