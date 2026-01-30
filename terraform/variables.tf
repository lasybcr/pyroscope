variable "docker_host" {
  description = "Docker daemon socket"
  type        = string
  default     = "unix:///var/run/docker.sock"
}

variable "pyroscope_image" {
  description = "Pyroscope container image"
  type        = string
  default     = "grafana/pyroscope:latest"
}

variable "prometheus_image" {
  description = "Prometheus container image"
  type        = string
  default     = "prom/prometheus:v2.53.0"
}

variable "grafana_image" {
  description = "Grafana container image"
  type        = string
  default     = "grafana/grafana:11.1.0"
}

variable "grafana_admin_user" {
  description = "Grafana admin username"
  type        = string
  default     = "admin"
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "bank_app_image" {
  description = "Pre-built bank microservice image (shared by all services)"
  type        = string
  default     = "pyroscope-vertx-app:latest"
}

variable "pyroscope_agent_jar" {
  description = "Path to Pyroscope agent jar inside the app container"
  type        = string
  default     = "/opt/pyroscope/pyroscope.jar"
}

variable "project_dir" {
  description = "Absolute path to the pyroscope project root (for config volume mounts)"
  type        = string
}
