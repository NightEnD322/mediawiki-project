resource "yandex_vpc_network" "wiki" {
  name      = "${var.project_name}-network"
  folder_id = var.folder_id
}

resource "yandex_vpc_subnet" "zone_a" {
  name           = "${var.project_name}-subnet-a"
  folder_id      = var.folder_id
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.wiki.id
  v4_cidr_blocks = ["10.20.1.0/24"]
  route_table_id = yandex_vpc_route_table.nat.id
}

resource "yandex_vpc_subnet" "zone_b" {
  name           = "${var.project_name}-subnet-b"
  folder_id      = var.folder_id
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.wiki.id
  v4_cidr_blocks = ["10.20.2.0/24"]
  route_table_id = yandex_vpc_route_table.nat.id
}

resource "yandex_vpc_security_group" "edge" {
  name        = "${var.project_name}-edge-sg"
  description = "Nginx, Zabbix and NFS"
  network_id  = yandex_vpc_network.wiki.id

  ingress {
    protocol       = "TCP"
    description    = "SSH only from management VM"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol       = "TCP"
    description    = "Public HTTP required by the assignment"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol       = "TCP"
    description    = "NFSv4 from project subnets"
    port           = 2049
    v4_cidr_blocks = ["10.20.1.0/24", "10.20.2.0/24"]
  }

  egress {
    protocol       = "ANY"
    description    = "Outbound package and service traffic"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_vpc_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "MediaWiki application nodes"
  network_id  = yandex_vpc_network.wiki.id

  ingress {
    protocol       = "TCP"
    description    = "SSH from edge-ops jump host"
    port           = 22
    v4_cidr_blocks = ["10.20.1.17/32"]
  }

  ingress {
    protocol       = "TCP"
    description    = "HTTP from the edge load balancer subnet"
    port           = 80
    v4_cidr_blocks = ["10.20.1.0/24"]
  }

  ingress {
    protocol       = "TCP"
    description    = "Zabbix passive agent checks"
    port           = 10050
    v4_cidr_blocks = ["10.20.1.0/24"]
  }

  egress {
    protocol       = "ANY"
    description    = "Outbound package and service traffic"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_vpc_security_group" "database" {
  name        = "${var.project_name}-database-sg"
  description = "PostgreSQL primary and standby"
  network_id  = yandex_vpc_network.wiki.id

  ingress {
    protocol       = "TCP"
    description    = "SSH from edge-ops jump host"
    port           = 22
    v4_cidr_blocks = ["10.20.1.17/32"]
  }

  ingress {
    protocol       = "TCP"
    description    = "PostgreSQL client traffic and replication"
    port           = 5432
    v4_cidr_blocks = ["10.20.1.0/24", "10.20.2.0/24"]
  }

  ingress {
    protocol       = "TCP"
    description    = "Zabbix passive agent checks"
    port           = 10050
    v4_cidr_blocks = ["10.20.1.0/24"]
  }

  egress {
    protocol       = "ANY"
    description    = "Outbound package and replication traffic"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "yandex_vpc_gateway" "nat" {
  name      = "mediawiki-egress-nat"
  folder_id = var.folder_id

  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "nat" {
  name       = "mediawiki-nat-routes"
  folder_id  = var.folder_id
  network_id = yandex_vpc_network.wiki.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat.id
  }
}
