variable "environment" {
  description = "Environment name; the release goes into namespace greeter-<environment>."
  type        = string
}

variable "greeting_name" {
  description = "GREETING_NAME for the service."
  type        = string
  validation {
    condition     = length(trimspace(var.greeting_name)) > 0
    error_message = "greeting_name must not be blank; the service refuses to start without it."
  }
}

variable "replicas" {
  type = number
  validation {
    # With one replica the PDB (maxUnavailable 1) lets a drain take the only pod.
    condition     = var.replicas >= 2 && floor(var.replicas) == var.replicas
    error_message = "replicas must be a whole number >= 2, or a node drain takes the service down."
  }
}

variable "image_tag" {
  description = "Tag of the greeter image already loaded into the cluster."
  type        = string
}

variable "node_port" {
  type = number
  validation {
    # Only these are mapped to the host in kind/cluster.yaml. Anything else
    # deploys fine and is unreachable.
    condition     = contains([30080, 30081, 30082], var.node_port)
    error_message = "node_port must be one kind maps to the host: 30080, 30081 or 30082."
  }
}
