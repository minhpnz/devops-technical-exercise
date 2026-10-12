# GitOps bootstrap (extension C). Terraform installs Flux, the in-cluster git
# server and the two Flux objects that point at it. From then on Flux owns the
# greeter releases; infra/dev and infra/prod must no longer apply them (see
# scripts/gitops-handover.sh and DECISIONS.md).
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

variable "git_server_image" {
  description = "Built by `make gitops-image` and side-loaded into kind."
  type        = string
  default     = "git-server:0.1.2"
}

provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.kubeconfig)
    config_context = "kind-greeter"
  }
}

resource "helm_release" "flux" {
  name             = "flux"
  namespace        = "flux-system"
  create_namespace = true
  repository       = "https://fluxcd-community.github.io/helm-charts"
  chart            = "flux2"
  version          = "2.19.1"

  values = [file("${path.module}/../../gitops/flux-values.yaml")]

  wait    = true
  timeout = 300
  atomic  = true

  # Uninstalling Flux removes its CRDs, which deletes every HelmRelease, and
  # helm-controller's finalizers uninstall the apps. `terraform destroy` here
  # must never be the way the applications go away.
  lifecycle {
    prevent_destroy = true
  }
}

resource "helm_release" "bootstrap" {
  name      = "gitops-bootstrap"
  namespace = "flux-system"
  chart     = "${path.module}/../../gitops/bootstrap"

  values = [yamlencode({
    gitServer = { image = var.git_server_image }
  })]

  # The Flux CRDs come from the release above.
  depends_on = [helm_release.flux]
  # Don't wait on the Kustomization: it can't go Ready until the repo has been
  # pushed, which happens after apply.
  wait = false

  # Deleting the root Kustomization (prune: true) garbage-collects both
  # HelmReleases, which uninstalls dev and prod. Hand back first
  # (`make gitops-handback`), then remove this block deliberately.
  lifecycle {
    prevent_destroy = true
  }
}
