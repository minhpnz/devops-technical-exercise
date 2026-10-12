# Identical in every environment directory; the environment is the directory
# name and the differences live in terraform.tfvars.
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

variable "greeting_name" { type = string }
variable "replicas" { type = number }
variable "image_tag" { type = string }
variable "node_port" { type = number }

provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.kubeconfig)
    config_context = "kind-greeter"
  }
}

module "greeter" {
  source = "../modules/greeter"

  environment   = basename(abspath(path.root))
  greeting_name = var.greeting_name
  replicas      = var.replicas
  image_tag     = var.image_tag
  node_port     = var.node_port
}

output "url" {
  value = module.greeter.url
}
