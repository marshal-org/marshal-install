output "app_url" {
  description = "Marshal web console + API URL."
  value       = module.marshal.app_url
}

output "namespace" {
  description = "Control-plane namespace."
  value       = module.marshal.namespace
}

output "spaces_namespace" {
  description = "Session-pod namespace."
  value       = module.marshal.spaces_namespace
}

output "chart_version" {
  description = "Installed product version."
  value       = module.marshal.chart_version
}

output "next_steps" {
  description = "Verify + reach the deployment."
  value       = module.marshal.next_steps
}
