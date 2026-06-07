variable "image_url" {
  type        = string
  description = "Debian 13 genericcloud qcow2 image URL"
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

variable "image_checksum_url" {
  type        = string
  description = "Checksum file URL for the source image"
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
}

variable "disk_size" {
  type        = string
  description = "Output image size"
  default     = "10G"
}

variable "memory" {
  type        = number
  description = "VM memory in MB"
  default     = 4096
}

variable "cpus" {
  type        = number
  description = "VM CPU count"
  default     = 4
}

variable "output_directory" {
  type        = string
  description = "Packer output directory. Empty string => <template-dir>/../../build"
  default     = ""
}

variable "output_name" {
  type        = string
  description = "Output qcow2 file name"
  default     = "debian-13-botwork.qcow2"
}

variable "accelerator" {
  type        = string
  description = "QEMU accelerator (kvm or none)"
  default     = "kvm"
}

variable "ssh_timeout" {
  type        = string
  description = "Timeout for initial SSH access"
  default     = "30m"
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to the ephemeral private key used by Packer"
  default     = "../../../build/packer_ssh_key"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key injected into cloud-init for debian/bot users"
  default     = ""

  validation {
    condition = can(
      regex("^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)\\s+", trimspace(var.ssh_public_key))
    )
    error_message = "Provide a valid SSH public key via -var 'ssh_public_key=...'."
  }
}
