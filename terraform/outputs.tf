output "grafana_url" {
  value = "http://localhost:3000"
}

output "pyroscope_url" {
  value = "http://localhost:4040"
}

output "prometheus_url" {
  value = "http://localhost:9090"
}

output "bank_service_urls" {
  value = {
    for key, svc in local.bank_services :
    key => "http://localhost:${svc.port}"
  }
}
