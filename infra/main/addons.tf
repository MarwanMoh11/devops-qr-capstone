locals {
  # No aws-ebs-csi-driver on purpose: a stray PVC then stays Pending instead of
  # creating an EBS volume that would outlive the cluster.
  addons = {
    # Networking and the Pod Identity agent must exist before nodes join.
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    amazon-cloudwatch-observability = {
      most_recent = true
      # Container Insights metrics only; container logs (fluent-bit) are off.
      # Application Signals auto monitor (default on since add-on v5.0.0) would
      # instrument every Service's pods and bill per request; it is opted out with
      # the key AWS documents under "Opt out of Application Signals":
      # https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Observability-EKS-addon.html#Opting-out-App-Signals
      configuration_values = jsonencode({
        containerLogs = { enabled = false }
        manager = {
          applicationSignals = {
            autoMonitor = { monitorAllServices = false }
          }
        }
      })
      # The add-on creates the association for its own ServiceAccount.
      pod_identity_association = [{
        role_arn        = module.cloudwatch_agent_pod_identity.iam_role_arn
        service_account = "cloudwatch-agent"
      }]
    }
  }
}
