# module.marshal is count-based (absent in the provision-only path), so read it
# with one() — null when deploy_cluster = true.

output "app_url" {
  description = "Marshal web console + API URL (install path)."
  value       = one(module.marshal[*].app_url)
}

output "namespace" {
  description = "Control-plane namespace (install path)."
  value       = one(module.marshal[*].namespace)
}

output "spaces_namespace" {
  description = "Session-pod namespace (install path)."
  value       = one(module.marshal[*].spaces_namespace)
}

output "chart_version" {
  description = "Installed product version (install path)."
  value       = one(module.marshal[*].chart_version)
}

output "k3s_external_ip" {
  description = "Static external IP of the provisioned node (public_ip = true); null otherwise. Point the app host's DNS A record here."
  value       = one(google_compute_address.node[*].address)
}

output "next_steps" {
  description = "What to do next."
  value = var.deploy_cluster ? (
    <<-EOT
      k3s node "${var.release_name}-k3s" is being provisioned in ${var.zone}.
      ${var.public_ip ? "Public static IP: ${one(google_compute_address.node[*].address)} (tcp/80+443). Admin access is still IAP only." : "It has NO public IP — reach it over IAP."}

      1. Wait for k3s to finish installing (startup script), then fetch its kubeconfig:
           gcloud compute ssh ${var.release_name}-k3s --zone ${var.zone} --tunnel-through-iap \
             --command 'sudo cat /etc/rancher/k3s/k3s.yaml' > k3s.yaml
         Rewrite the server address from https://127.0.0.1:6443 to the node's
         internal IP (or keep a tunnel open on 6443).

      2. Install Marshal onto it — re-apply with deploy_cluster=false:
           terraform apply -var deploy_cluster=false -var kubeconfig_path=./k3s.yaml <your other vars>

      terraform must reach the node's private API (6443) — run it from inside the
      VPC / over a bastion / with an IAP tunnel, and set admin_source_ranges.
    EOT
  ) : one(module.marshal[*].next_steps)
}
