locals {
  chart = "${path.module}/../../../charts/greeter"
  # The provider only notices chart version and value changes, so an edited
  # template in this local chart would plan as "No changes". Feeding a hash of
  # the chart's files in as a value makes any edit show up as a values diff.
  chart_hash = sha1(join("", [for f in sort(fileset(local.chart, "**")) : filesha1("${local.chart}/${f}")]))
}

resource "helm_release" "greeter" {
  name             = "greeter"
  namespace        = "greeter-${var.environment}"
  create_namespace = true
  chart            = local.chart

  # Only what differs per environment. Everything else is a chart default.
  values = [yamlencode({
    greetingName = var.greeting_name
    replicas     = var.replicas
    image        = { tag = var.image_tag }
    service      = { nodePort = var.node_port }
    chartHash    = local.chart_hash # not used by any template
  })]

  # Apply only returns once every pod has passed readiness; a failed rollout
  # is rolled back rather than left half-done.
  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true
}

output "url" {
  value = "http://127.0.0.1:${var.node_port}/"
}

output "namespace" {
  value = helm_release.greeter.namespace
}
