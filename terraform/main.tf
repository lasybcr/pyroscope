terraform {
  required_version = ">= 1.0"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {
  host = var.docker_host
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
resource "docker_network" "monitoring" {
  name   = "pyroscope-monitoring"
  driver = "bridge"
}

# ---------------------------------------------------------------------------
# Volumes
# ---------------------------------------------------------------------------
resource "docker_volume" "pyroscope_data" {
  name = "pyroscope-data"
}

resource "docker_volume" "prometheus_data" {
  name = "prometheus-data"
}

resource "docker_volume" "grafana_data" {
  name = "grafana-data"
}

# ---------------------------------------------------------------------------
# Pyroscope
# ---------------------------------------------------------------------------
resource "docker_image" "pyroscope" {
  name         = var.pyroscope_image
  keep_locally = true
}

resource "docker_container" "pyroscope" {
  name  = "pyroscope"
  image = docker_image.pyroscope.image_id

  ports {
    internal = 4040
    external = 4040
  }

  volumes {
    volume_name    = docker_volume.pyroscope_data.name
    container_path = "/data"
  }

  volumes {
    host_path      = "${var.project_dir}/config/pyroscope/pyroscope.yaml"
    container_path = "/etc/pyroscope/config.yaml"
    read_only      = true
  }

  command = ["-config.file=/etc/pyroscope/config.yaml"]

  networks_advanced {
    name = docker_network.monitoring.id
  }
}

# ---------------------------------------------------------------------------
# Prometheus
# ---------------------------------------------------------------------------
resource "docker_image" "prometheus" {
  name         = var.prometheus_image
  keep_locally = true
}

resource "docker_container" "prometheus" {
  name  = "prometheus"
  image = docker_image.prometheus.image_id

  ports {
    internal = 9090
    external = 9090
  }

  volumes {
    host_path      = "${var.project_dir}/config/prometheus/prometheus.yml"
    container_path = "/etc/prometheus/prometheus.yml"
    read_only      = true
  }

  volumes {
    volume_name    = docker_volume.prometheus_data.name
    container_path = "/prometheus"
  }

  networks_advanced {
    name = docker_network.monitoring.id
  }
}

# ---------------------------------------------------------------------------
# Grafana
# ---------------------------------------------------------------------------
resource "docker_image" "grafana" {
  name         = var.grafana_image
  keep_locally = true
}

resource "docker_container" "grafana" {
  name  = "grafana"
  image = docker_image.grafana.image_id

  ports {
    internal = 3000
    external = 3000
  }

  env = [
    "GF_SECURITY_ADMIN_USER=${var.grafana_admin_user}",
    "GF_SECURITY_ADMIN_PASSWORD=${var.grafana_admin_password}",
    "GF_INSTALL_PLUGINS=grafana-pyroscope-app",
  ]

  volumes {
    volume_name    = docker_volume.grafana_data.name
    container_path = "/var/lib/grafana"
  }

  volumes {
    host_path      = "${var.project_dir}/config/grafana/provisioning"
    container_path = "/etc/grafana/provisioning"
    read_only      = true
  }

  volumes {
    host_path      = "${var.project_dir}/config/grafana/dashboards"
    container_path = "/var/lib/grafana/dashboards"
    read_only      = true
  }

  networks_advanced {
    name = docker_network.monitoring.id
  }

  depends_on = [
    docker_container.prometheus,
    docker_container.pyroscope,
  ]
}

# ---------------------------------------------------------------------------
# Bank Microservices (locals)
# ---------------------------------------------------------------------------
locals {
  bank_services = {
    api_gateway = {
      name       = "api-gateway"
      port       = 8080
      verticle   = "default"
      app_name   = "bank-api-gateway"
    }
    order_service = {
      name       = "order-service"
      port       = 8081
      verticle   = "order"
      app_name   = "bank-order-service"
    }
    payment_service = {
      name       = "payment-service"
      port       = 8082
      verticle   = "payment"
      app_name   = "bank-payment-service"
    }
    fraud_service = {
      name       = "fraud-service"
      port       = 8083
      verticle   = "fraud"
      app_name   = "bank-fraud-service"
    }
    account_service = {
      name       = "account-service"
      port       = 8084
      verticle   = "account"
      app_name   = "bank-account-service"
    }
    loan_service = {
      name       = "loan-service"
      port       = 8085
      verticle   = "loan"
      app_name   = "bank-loan-service"
    }
    notification_service = {
      name       = "notification-service"
      port       = 8086
      verticle   = "notification"
      app_name   = "bank-notification-service"
    }
  }
}

# ---------------------------------------------------------------------------
# Bank Microservices
# ---------------------------------------------------------------------------
resource "docker_container" "bank_service" {
  for_each = local.bank_services

  name  = each.value.name
  image = var.bank_app_image

  ports {
    internal = 8080
    external = each.value.port
  }

  env = concat(
    each.value.verticle != "default" ? ["VERTICLE=${each.value.verticle}"] : [],
    [
      "JAVA_TOOL_OPTIONS=-javaagent:${var.pyroscope_agent_jar} -Dpyroscope.application.name=${each.value.app_name} -Dpyroscope.server.address=http://pyroscope:4040 -Dpyroscope.format=jfr -Dpyroscope.profiler.event=cpu,alloc,lock -Dpyroscope.profiler.alloc=512k -Dpyroscope.labels.env=production -Dpyroscope.labels.service=${each.value.name} -Dpyroscope.log.level=info",
    ],
  )

  networks_advanced {
    name = docker_network.monitoring.id
  }

  depends_on = [docker_container.pyroscope]
}
