variable "openstack_username" {}
variable "openstack_password" {}
variable "openstack_tenant_name" {}
variable "openstack_region" {}
variable "openstack_image_id" {
  description = "Image ID to use for the VMs"
  type        = string
  default     = "08078bd1-323b-4ef6-ba98-de138ac7062f"  # jammy daily
}
variable "openstack_flavor_id" {
  description = "Flavor of the VMs"
  type        = string
  default     = "587ba50a-9ca6-4809-b08a-fb448980b056"  # prod-cpu4-ram8-disk50
}
variable "openstack_key_pair" {
  description = "Keypair name to be used"
  type        = string
  default     = "rocks-team"  # must already exist
}