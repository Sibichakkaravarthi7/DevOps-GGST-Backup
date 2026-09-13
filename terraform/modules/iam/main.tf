data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  control_plane_role_name = "${var.cluster_name}-control-plane-role"
  worker_role_name        = "${var.cluster_name}-worker-role"

  ssm_parameter_arn = "arn:${data.aws_partition.current.partition}:ssm:*:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_join_parameter}"

  common_tags = merge(
    {
      ManagedBy = "terraform"
      Cluster   = var.cluster_name
    },
    var.additional_tags
  )
}

# ================================================================
# CONTROL PLANE TRUST POLICY
# ================================================================

data "aws_iam_policy_document" "control_plane_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}

# ================================================================
# CONTROL PLANE ROLE
# ================================================================

resource "aws_iam_role" "control_plane" {
  name               = local.control_plane_role_name
  assume_role_policy = data.aws_iam_policy_document.control_plane_assume_role.json

  tags = local.common_tags
}

# ================================================================
# CONTROL PLANE - AWS CCM
# ================================================================

data "aws_iam_policy_document" "cloud_controller_manager" {
  statement {
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVolumes",
      "ec2:DescribeVpcs",
      "ec2:DescribeAvailabilityZones",
      "ec2:CreateSecurityGroup",
      "ec2:CreateTags",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:DeleteSecurityGroup",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyVolume",
      "ec2:AttachVolume",
      "ec2:DetachVolume",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress"
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "elasticloadbalancing:*"
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "iam:CreateServiceLinkedRole"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "cloud_controller_manager" {
  name        = "${var.cluster_name}-cloud-controller-manager"
  description = "AWS Cloud Controller Manager permissions for ${var.cluster_name}"

  policy = data.aws_iam_policy_document.cloud_controller_manager.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "control_plane_ccm" {
  role       = aws_iam_role.control_plane.name
  policy_arn = aws_iam_policy.cloud_controller_manager.arn
}

# ================================================================
# CONTROL PLANE - SSM JOIN PARAMETER
# ================================================================

data "aws_iam_policy_document" "control_plane_ssm" {
  statement {
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]

    resources = [
      local.ssm_parameter_arn
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "ssm:PutParameter"
    ]

    resources = [
      local.ssm_parameter_arn
    ]
  }
}

resource "aws_iam_policy" "control_plane_ssm" {
  name        = "${var.cluster_name}-control-plane-ssm"
  description = "SSM permissions for Kubernetes join parameter"

  policy = data.aws_iam_policy_document.control_plane_ssm.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "control_plane_ssm" {
  role       = aws_iam_role.control_plane.name
  policy_arn = aws_iam_policy.control_plane_ssm.arn
}

# ================================================================
# CONTROL PLANE INSTANCE PROFILE
# ================================================================

resource "aws_iam_instance_profile" "control_plane" {
  name = "${var.cluster_name}-control-plane-profile"
  role = aws_iam_role.control_plane.name

  tags = local.common_tags
}

# ================================================================
# WORKER TRUST POLICY
# ================================================================

data "aws_iam_policy_document" "worker_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}

# ================================================================
# WORKER ROLE
# ================================================================

resource "aws_iam_role" "worker" {
  name               = local.worker_role_name
  assume_role_policy = data.aws_iam_policy_document.worker_assume_role.json

  tags = local.common_tags
}

# ================================================================
# WORKER - CLUSTER AUTOSCALER
# ================================================================

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    effect = "Allow"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup"
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${var.cluster_name}-cluster-autoscaler"
  description = "Cluster Autoscaler permissions for ${var.cluster_name}"

  policy = data.aws_iam_policy_document.cluster_autoscaler.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "worker_cluster_autoscaler" {
  role       = aws_iam_role.worker.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# ================================================================
# WORKER - SSM JOIN PARAMETER
# ================================================================

data "aws_iam_policy_document" "worker_ssm_parameter" {
  statement {
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]

    resources = [
      local.ssm_parameter_arn
    ]
  }
}

resource "aws_iam_policy" "worker_ssm_parameter" {
  name        = "${var.cluster_name}-worker-ssm-parameter"
  description = "Worker access to Kubernetes join parameter"

  policy = data.aws_iam_policy_document.worker_ssm_parameter.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "worker_ssm_parameter" {
  role       = aws_iam_role.worker.name
  policy_arn = aws_iam_policy.worker_ssm_parameter.arn
}

# ================================================================
# WORKER - ECR READ
# ================================================================

resource "aws_iam_role_policy_attachment" "worker_ecr" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ================================================================
# WORKER - SSM MANAGED INSTANCE
# ================================================================

resource "aws_iam_role_policy_attachment" "worker_ssm" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ================================================================
# WORKER INSTANCE PROFILE
# ================================================================

resource "aws_iam_instance_profile" "worker" {
  name = "${var.cluster_name}-worker-profile"
  role = aws_iam_role.worker.name

  tags = local.common_tags
}
