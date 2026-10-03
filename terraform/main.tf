terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 1.0"
}

provider "yandex" {
  zone                     = "ru-central1-a"
  service_account_key_file = pathexpand("~/.config/yandex-cloud/terraform/terraform-mediawiki-sa-key.json")
}

data "yandex_resourcemanager_folder" "project" {
  folder_id = var.folder_id
}

data "yandex_compute_image" "ubuntu_2204" {
  family = "ubuntu-2204-lts"
}
