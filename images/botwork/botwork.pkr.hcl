packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1.2"
    }
  }
}

locals {
  template_root = abspath(path.root)

  rendered_user_data = replace(
    file("${local.template_root}/../_shared/cloud-init/user-data"),
    "REPLACE_WITH_SSH_PUBLIC_KEY",
    var.ssh_public_key
  )

  # Anchor output_directory to a subdirectory of build/ so `packer build -force`
  # can wipe it without nuking sibling state (packer-cache/, packer-plugins/,
  # ephemeral SSH keys, etc.).
  output_directory = var.output_directory != "" ? var.output_directory : "${local.template_root}/../../build/output"
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
    "meta-data" = file("${local.template_root}/../_shared/cloud-init/meta-data")
  }

  shutdown_command = "sudo poweroff"
}

build {
  name    = "debian-trixie-botwork"
  sources = ["source.qemu.debian"]

  # Ensure the staging directory exists and is writable by the SSH user
  # before the file provisioners try to scp into it.
  provisioner "shell" {
    inline = [
      "mkdir -p /tmp/botwork-build-context",
      "chmod 0755 /tmp/botwork-build-context",
    ]
  }

  provisioner "file" {
    source      = "${local.template_root}/payload/envoy"
    destination = "/tmp/botwork-build-context/"
  }

  provisioner "file" {
    source      = "${local.template_root}/payload/systemd"
    destination = "/tmp/botwork-build-context/"
  }

  provisioner "file" {
    source      = "${local.template_root}/../../build/bin"
    destination = "/tmp/botwork-build-context/"
  }

  provisioner "file" {
    source      = "${local.template_root}/../../build/images/baked"
    destination = "/tmp/botwork-build-context/images"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; sudo -E {{ .Path }}"
    scripts = [
      "${local.template_root}/../_shared/provisioners/00-base.sh",
      "${local.template_root}/../_shared/provisioners/10-bot-user.sh",
      "${local.template_root}/../_shared/provisioners/20-botwork-stack.sh",
      "${local.template_root}/../_shared/provisioners/99-cleanup.sh",
    ]
  }
}
