provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      Cluster   = var.cluster_name
      ManagedBy = "terraform"
    }
  }
}
