locals {
  servers = {
    edge-ops = {
      zone              = "ru-central1-a"
      subnet_id         = yandex_vpc_subnet.zone_a.id
      cores             = 2
      memory            = 4
      boot_disk_size    = 20
      security_group_id = yandex_vpc_security_group.edge.id
    }
    app1 = {
      zone              = "ru-central1-a"
      subnet_id         = yandex_vpc_subnet.zone_a.id
      cores             = 2
      memory            = 2
      boot_disk_size    = 20
      security_group_id = yandex_vpc_security_group.app.id
    }
    app2 = {
      zone              = "ru-central1-b"
      subnet_id         = yandex_vpc_subnet.zone_b.id
      cores             = 2
      memory            = 2
      boot_disk_size    = 20
      security_group_id = yandex_vpc_security_group.app.id
    }
    db1 = {
      zone              = "ru-central1-a"
      subnet_id         = yandex_vpc_subnet.zone_a.id
      cores             = 2
      memory            = 4
      boot_disk_size    = 30
      security_group_id = yandex_vpc_security_group.database.id
    }
    db2 = {
      zone              = "ru-central1-b"
      subnet_id         = yandex_vpc_subnet.zone_b.id
      cores             = 2
      memory            = 4
      boot_disk_size    = 30
      security_group_id = yandex_vpc_security_group.database.id
    }
  }
}

resource "yandex_compute_disk" "shared_data" {
  name      = "${var.project_name}-shared-data"
  folder_id = var.folder_id
  zone      = "ru-central1-a"
  type      = "network-hdd"
  size      = 50
}

resource "yandex_compute_instance" "wiki" {
  for_each = local.servers

  name        = "${var.project_name}-${each.key}"
  folder_id   = var.folder_id
  zone        = each.value.zone
  platform_id = "standard-v3"

  resources {
    cores         = each.value.cores
    memory        = each.value.memory
    core_fraction = 20
  }

  boot_disk {
    auto_delete = true

    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id
      size     = each.value.boot_disk_size
      type     = "network-hdd"
    }
  }

  network_interface {
    subnet_id          = each.value.subnet_id
    nat                = each.key == "edge-ops"
    security_group_ids = [each.value.security_group_id]
  }

  metadata = {
    "ssh-keys" = "ubuntu:${var.ssh_public_key}"
  }

  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [
      boot_disk[0].initialize_params[0].image_id
    ]
  }

  dynamic "secondary_disk" {
    for_each = each.key == "edge-ops" ? [yandex_compute_disk.shared_data.id] : []

    content {
      disk_id     = secondary_disk.value
      device_name = "wiki-shared-data"
      auto_delete = false
    }
  }
}

output "server_addresses" {
  description = "Private and public addresses for SSH and Ansible inventory"
  value = {
    for name, instance in yandex_compute_instance.wiki : name => {
      private_ip = instance.network_interface[0].ip_address
      public_ip  = instance.network_interface[0].nat_ip_address
      zone       = instance.zone
    }
  }
}
