packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1.2"
    }
  }
}

locals {
  rendered_user_data = replace(
    file("cloud-init/user-data"),
    "REPLACE_WITH_SSH_PUBLIC_KEY",
    var.ssh_public_key
  )

  # Anchor output_directory to a subdirectory of build/ so `packer build -force`
  # can wipe it without nuking sibling state (packer-cache/, packer-plugins/,
  # ephemeral SSH keys, etc.).
  output_directory = var.output_directory != "" ? var.output_directory : "${path.root}/../build/output"
}

source "qemu" "debian" {
  iso_url      = var.image_url
  iso_checksum = "file:${var.image_checksum_url}"

  disk_image       = true
  format           = "qcow2"
  accelerator      = var.accelerator
  headless         = true
  cpus             = var.cpus
  memory           = var.memory
  disk_size        = var.disk_size
  output_directory = local.output_directory
  vm_name          = var.output_name

  ssh_username         = "debian"
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = var.ssh_timeout

  cd_label = "cidata"
  cd_content = {
    "user-data" = local.rendered_user_data
    "meta-data" = file("cloud-init/meta-data")
  }

  shutdown_command = "sudo poweroff"
}

build {
  name    = "debian-trixie-botspace"
  sources = ["source.qemu.debian"]

  # Ensure the staging directory exists and is writable by the SSH user
  # before the file provisioners try to scp into it.
  provisioner "shell" {
    inline = [
      "mkdir -p /tmp/botspace-build-context",
      "chmod 0755 /tmp/botspace-build-context",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../envoy"
    destination = "/tmp/botspace-build-context/"
  }

  provisioner "file" {
    source      = "${path.root}/../systemd"
    destination = "/tmp/botspace-build-context/"
  }

  provisioner "file" {
    source      = "${path.root}/../build/bin"
    destination = "/tmp/botspace-build-context/"
  }

  provisioner "file" {
    source      = "${path.root}/../build/images/baked"
    destination = "/tmp/botspace-build-context/images"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; sudo -E {{ .Path }}"
    scripts = [
      "${path.root}/scripts/00-base.sh",
      "${path.root}/scripts/10-bot-user.sh",
      "${path.root}/scripts/20-botspace-stack.sh",
      "${path.root}/scripts/99-cleanup.sh",
    ]
  }
}
