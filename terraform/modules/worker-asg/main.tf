locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Cluster   = var.cluster_name
      Role      = "worker"

      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    },
    var.additional_tags
  )

  worker_bootstrap = var.user_data != null ? var.user_data : templatefile(
    "${path.module}/templates/worker-bootstrap.sh.tftpl",
    {
      control_plane_private_ip = var.control_plane_private_ip
      aws_region               = var.aws_region
      ssm_join_parameter       = var.ssm_join_parameter
      kubernetes_version       = var.kubernetes_version
      kubernetes_minor_version = var.kubernetes_minor_version
    }
  )
}

resource "aws_launch_template" "this" {
  name = "${var.cluster_name}-worker"

  image_id      = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name

  user_data = base64encode(local.worker_bootstrap)

  iam_instance_profile {
    name = var.instance_profile_name
  }

  vpc_security_group_ids = [
    var.security_group_id
  ]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = var.root_volume_type
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(
      local.common_tags,
      {
        Name = "${var.cluster_name}-worker"
      }
    )
  }

  tag_specifications {
    resource_type = "volume"

    tags = local.common_tags
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name = "${var.cluster_name}-worker-asg"

  min_size         = var.min_size
  desired_capacity = var.desired_size
  max_size         = var.max_size

  vpc_zone_identifier = var.subnet_ids

  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = false
  }

  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-worker"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
