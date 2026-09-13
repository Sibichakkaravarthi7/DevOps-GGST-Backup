module "network" {
  source = "../../modules/network"

  network_mode = var.network_mode

  vpc_id                  = var.vpc_id
  control_plane_subnet_id = var.control_plane_subnet_id
  worker_subnet_ids       = var.worker_subnet_ids

  additional_tags = var.additional_tags
}

module "iam" {
  source = "../../modules/iam"

  cluster_name       = var.cluster_name
  ssm_join_parameter = var.ssm_join_parameter

  additional_tags = var.additional_tags
}

module "security" {
  source = "../../modules/security"

  cluster_name = var.cluster_name
  vpc_id       = module.network.vpc_id

  admin_cidr        = var.admin_cidr
  enable_ssh        = var.enable_ssh
  enable_public_api = var.enable_public_api
  enable_nodeport   = var.enable_nodeport
  enable_http_https = var.enable_http_https

  additional_tags = var.additional_tags
}

module "control_plane" {
  source = "../../modules/control-plane"

  cluster_name = var.cluster_name

  ami_id        = var.ami_id
  instance_type = var.control_plane_instance_type

  subnet_id = module.network.control_plane_subnet_id

  security_group_id = module.security.control_plane_security_group_id

  instance_profile_name = module.iam.control_plane_instance_profile_name

  key_name = var.key_name

  root_volume_size = var.root_volume_size
  root_volume_type = var.root_volume_type

  additional_tags = var.additional_tags
}

module "worker_asg" {
  source = "../../modules/worker-asg"

  cluster_name = var.cluster_name

  ami_id        = var.ami_id
  instance_type = var.worker_instance_type

  subnet_ids = module.network.worker_subnet_ids

  security_group_id = module.security.worker_security_group_id

  instance_profile_name = module.iam.worker_instance_profile_name

  key_name = var.key_name

  min_size     = var.worker_min_size
  desired_size = var.worker_desired_size
  max_size     = var.worker_max_size

  root_volume_size = var.root_volume_size
  root_volume_type = var.root_volume_type

  additional_tags = var.additional_tags
}
