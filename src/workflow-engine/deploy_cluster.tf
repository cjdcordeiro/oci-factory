terraform {
  required_version = ">= 1.5.5"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.51.1"
    }
  }
}

# Configure the OpenStack Provider
# See https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs
provider "openstack" {
  user_name   = var.openstack_username
  password    = var.openstack_password
  tenant_name = var.openstack_tenant_name
  region      = var.openstack_region
  # Forward the OS remote ports such that the auth_url, network and compute
  # urls are all reachable on localhost. 
  auth_url = "https://keystone.ps5.canonical.com:5000/v3/"
  insecure = true
  # These overrides should be removed, but while both endpoints claim to be
  # public, they are timing out when being accessed
  endpoint_overrides = {
    "network" = "https://localhost:9696/v2.0/"
    "compute" = "https://localhost:8774/v2.1/"
  }
}

resource "random_id" "cluster_token" {
  byte_length = 16
}

resource "tls_private_key" "controller_ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

################## CONTROL PLANE

data "cloudinit_config" "control_config" {
  gzip          = true
  base64_encode = true
  part {
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/cloud-init.yml", {
      clusterforming_cmd : "microk8s add-node --token ${random_id.cluster_token.hex}",
      custom_ssh_pub_key : "${tls_private_key.controller_ssh_key.public_key_openssh}"
    })
  }

  depends_on = [
    random_id.cluster_token,
    tls_private_key.controller_ssh_key
  ]
}

resource "openstack_compute_instance_v2" "rocks-temporal-workers-controller" {
  # rocks-temporal-workers-controller is the microk8s control plane
  name            = "rocks-temporal-workers-controller"
  # The images are refreshed regularly, so the IDs might change.
  # Double check the desired Jammy image ID before deploying.
  image_id        = var.openstack_image_id
  flavor_id       = var.openstack_flavor_id
  key_pair        = var.openstack_key_pair
  security_groups = ["default"]
  user_data       = data.cloudinit_config.control_config.rendered

  network {
    name = "net_prod-rocks"
  }
}

################## WORKERNODE

data "cloudinit_config" "workernode_config" {
  gzip          = true
  base64_encode = true
  part {
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/cloud-init.yml", {
      # The `microk8s join` command will be done with a remote-exec because
      # we first need to make this the workernode's hostname is added to the
      # controller's /etc/hosts (which is also being done in post, below)
      clusterforming_cmd : "",
      custom_ssh_pub_key : "${tls_private_key.controller_ssh_key.public_key_openssh}"
    })
  }

  depends_on = [
    random_id.cluster_token,
    openstack_compute_instance_v2.rocks-temporal-workers-controller
  ]
}

resource "openstack_compute_instance_v2" "rocks-temporal-workers-workernode" {
  # rocks-temporal-workers-controller is the microk8s control plane
  name            = "rocks-temporal-workers-workernode"
  image_id        = var.openstack_image_id
  flavor_id       = var.openstack_flavor_id
  key_pair        = var.openstack_key_pair
  security_groups = ["default"]
  user_data       = data.cloudinit_config.workernode_config.rendered

  network {
    name = "net_prod-rocks"
  }
}

################## POST ACTIONS

# Add the workernode's IP to the controller's /etc/hosts, otherwise the join
# command with fail with:
#  > Connection failed. The hostname ... does not resolve to the IP...(400)
resource "null_resource" "controller_etc_hosts" {
  depends_on = [
    openstack_compute_instance_v2.rocks-temporal-workers-controller,
    openstack_compute_instance_v2.rocks-temporal-workers-workernode,
    tls_private_key.controller_ssh_key
  ]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = tls_private_key.controller_ssh_key.private_key_pem
    host        = openstack_compute_instance_v2.rocks-temporal-workers-controller.network.0.fixed_ip_v4
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${openstack_compute_instance_v2.rocks-temporal-workers-workernode.network.0.fixed_ip_v4} ${openstack_compute_instance_v2.rocks-temporal-workers-workernode.name}' | sudo tee -a /etc/hosts",
    ]
  }
}

# At the very end, join the workernode to the controller, forming a cluster.
resource "null_resource" "microk8s_join" {
  depends_on = [
    openstack_compute_instance_v2.rocks-temporal-workers-controller,
    openstack_compute_instance_v2.rocks-temporal-workers-workernode,
    tls_private_key.controller_ssh_key,
    null_resource.controller_etc_hosts
  ]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = tls_private_key.controller_ssh_key.private_key_pem
    host        = openstack_compute_instance_v2.rocks-temporal-workers-workernode.network.0.fixed_ip_v4
  }

  provisioner "remote-exec" {
    inline = [
      # Wait for cloud-init to finish so we have microk8s up and running
      "cloud-init status --wait",
      "sudo microk8s join ${openstack_compute_instance_v2.rocks-temporal-workers-controller.network.0.fixed_ip_v4}:25000/${random_id.cluster_token.hex} --worker"
    ]
  }
}
