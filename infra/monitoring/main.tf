# Prometheus for extension B. Its own root and state: it's platform, not part of
# either application environment, and tearing down dev shouldn't touch it.
terraform {
  required_version = ">= 1.6, < 2.0"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

variable "kubeconfig" {
  type    = string
  default = "~/.kube/config"
}

provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.kubeconfig)
    config_context = "kind-greeter"
  }
}

locals {
  monitoring = "${path.module}/../../monitoring"
}

resource "helm_release" "prometheus" {
  name             = "prometheus"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus"
  version          = "29.33.0"

  values = [
    file("${local.monitoring}/prometheus-values.yaml"),
    # The rules file is the same one promtool tests in CI.
    yamlencode({
      serverFiles = {
        "alerting_rules.yml" = yamldecode(file("${local.monitoring}/alerts.yaml"))
      }
    }),
  ]

  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true
}

output "url" {
  value = "http://127.0.0.1:30090/"
}
