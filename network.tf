data "google_compute_address" "nat_address" {
  count   = length(var.nat_address_name) == 0 ? 0 : 1
  name    = var.nat_address_name
  project = var.project
  region  = local.region
}

module "vpc" {
  source                  = "./modules/network"
  vpc_name                = trimspace(var.vpc_name)
  project                 = var.project
  prefix                  = var.prefix
  region                  = local.region
  subnet_names            = local.subnet_names
  create_subnets          = length(var.subnet_names) == 0 ? true : false
  gke_subnet_cidr         = var.gke_subnet_cidr
  misc_subnet_cidr        = var.misc_subnet_cidr
  gke_pod_subnet_cidr     = var.gke_pod_subnet_cidr
  gke_service_subnet_cidr = var.gke_service_subnet_cidr
}
