# Container Insights would create these itself, outside Terraform, and they would
# survive destroy. Pre-creating them makes Terraform own (and delete) them.
# They take seconds and the cluster takes 10+ minutes, so no depends_on is needed.
resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = toset(["performance", "application", "host", "dataplane"])

  name              = "/aws/containerinsights/${local.cluster_name}/${each.key}"
  retention_in_days = 1
}
