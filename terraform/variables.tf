variable "folder_id" {
  description = "ID папки Yandex Cloud для проекта"
  type        = string
}

variable "ssh_public_key" {
  description = "Публичный SSH-ключ для доступа к ВМ"
  type        = string
}

variable "project_name" {
  description = "Префикс имён ресурсов проекта"
  type        = string
  default     = "mediawiki"
}

variable "management_cidr" {
  description = "Публичный IPv4/CIDR управляющей ВМ, которой разрешён SSH"
  type        = string
}
