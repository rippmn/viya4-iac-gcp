provider "google" {
  credentials = var.service_account_keyfile != null ? file(var.service_account_keyfile) : null
  project     = var.project
}

provider "google-beta" {
  credentials = var.service_account_keyfile != null ? file(var.service_account_keyfile) : null
  project     = var.project
}


data "google_client_config" "current" {}

# Used for locals below.
data "google_compute_zones" "available" {
  region = local.region
}

locals {

  # get the region from "location", or else from the local config
  region = var.location != "" ? regex("^[a-z0-9]*-[a-z0-9]*", var.location) : data.google_client_config.current.region

  # get the zone from "location", or else from the local config. If none is set, default to the first zone in the region
  is_region  = var.location != "" ? var.location == regex("^[a-z0-9]*-[a-z0-9]*", var.location) : false
  first_zone = length(data.google_compute_zones.available.names) > 0 ? data.google_compute_zones.available.names[0] : ""
  # all_zones  = length(data.google_compute_zones.available.names) > 0 ? join(",", [for item in data.google_compute_zones.available.names : format("%s", item)]) : ""
  zone       = ( var.location != "" ? (local.is_region ? local.first_zone : var.location) : (data.google_client_config.current.zone == "" ? local.first_zone : data.google_client_config.current.zone) )
  location   = var.location != "" ? var.location : local.zone

  default_public_access_cidrs          = var.default_public_access_cidrs == null ? [] : var.default_public_access_cidrs
  vm_public_access_cidrs               = var.vm_public_access_cidrs == null ? local.default_public_access_cidrs : var.vm_public_access_cidrs
  postgres_public_access_cidrs         = var.postgres_public_access_cidrs == null ? local.default_public_access_cidrs : var.postgres_public_access_cidrs

  ssh_public_key = file(var.ssh_public_key)

  kubeconfig_path     = var.iac_tooling == "docker" ? "/workspace/${var.prefix}-gke-kubeconfig.conf" : "${var.prefix}-gke-kubeconfig.conf"

  taint_effects = { 
    NoSchedule       = "NO_SCHEDULE"
    PreferNoSchedule = "PREFER_NO_SCHEDULE"
    NoExecute        = "NO_EXECUTE"
  }

  node_pools_and_accelerator_taints = {
    for node_pool, settings in var.node_pools: node_pool => {
      accelerator_count = settings.accelerator_count
      accelerator_type  = settings.accelerator_type
      local_ssd_count   = settings.local_ssd_count
      max_nodes         = settings.max_nodes
      min_nodes         = settings.min_nodes
      node_labels       = settings.node_labels
      os_disk_size      = settings.os_disk_size
      vm_type           = settings.vm_type
      node_taints       = settings.accelerator_count >0 ? concat( settings.node_taints, ["nvidia.com/gpu=present:NoSchedule"]) : settings.node_taints
    }
  }

  node_pools = merge(local.node_pools_and_accelerator_taints, {
    default = {
      "vm_type"      = var.default_nodepool_vm_type
      "os_disk_size" = var.default_nodepool_os_disk_size
      "min_nodes"    = var.default_nodepool_min_nodes
      "max_nodes"    = var.default_nodepool_max_nodes
      "node_taints"  = var.default_nodepool_taints
      "node_labels" = merge(var.tags, var.default_nodepool_labels,{"kubernetes.azure.com/mode"="system"})
      "local_ssd_count" = var.default_nodepool_local_ssd_count
      "accelerator_count" = 0
      "accelerator_type" = ""
    }
  })

  subnet_names_defaults = {
    gke                     = "${var.prefix}-gke-subnet"
    misc                    = "${var.prefix}-misc-subnet"
    gke_pods_range_name     = "${var.prefix}-gke-pods"
    gke_services_range_name = "${var.prefix}-gke-services"
  }

  subnet_names        = length(var.subnet_names) == 0 ? local.subnet_names_defaults : var.subnet_names

  gke_subnet_cidr     = length(var.subnet_names) == 0 ? var.gke_subnet_cidr : module.vpc.subnets["gke"].ip_cidr_range
  misc_subnet_cidr    = length(var.subnet_names) == 0 ? var.misc_subnet_cidr : module.vpc.subnets["misc"].ip_cidr_range

  gke_pod_range_index = length(var.subnet_names) == 0 ? index(module.vpc.subnets["gke"].secondary_ip_range.*.range_name, local.subnet_names["gke_pods_range_name"]) : 0
  gke_pod_subnet_cidr = length(var.subnet_names) == 0 ? var.gke_pod_subnet_cidr : module.vpc.subnets["gke"].secondary_ip_range[local.gke_pod_range_index].ip_cidr_range

  filestore_size_in_gb = (
    var.filestore_size_in_gb == null
      ? ( contains(["BASIC_HDD","STANDARD"], upper(var.filestore_tier)) ? 1024 : 2560 )
      : var.filestore_size_in_gb
  )

}

data "external" "git_hash" {
  program = ["files/tools/iac_git_info.sh"]
}

data "external" "iac_tooling_version" {
  program = ["files/tools/iac_tooling_version.sh"]
}


resource "google_filestore_instance" "rwx" {
  name   = "${var.prefix}-rwx-filestore"
  count  = var.storage_type == "ha" ? 1 : 0 
  tier   = upper(var.filestore_tier)
  zone   = local.zone
  labels = var.tags

  file_shares {
    capacity_gb = local.filestore_size_in_gb
    name        = "volumes"
  }

  networks {
    network = module.vpc.network_name
    modes   = ["MODE_IPV4"]
  }
}

data "google_container_engine_versions" "gke-version" {
  provider = google-beta
  location       = var.regional ? local.region : local.zone
  version_prefix = "${var.kubernetes_version}."
}



