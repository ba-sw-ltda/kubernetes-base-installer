@{
    Name           = "gcp-secretmanager"
    Namespace      = "kube-system"
    RancherProject = "Security"

    UserConfig = @{
        # GCP Secret Manager CSI driver — mounts secrets as files via Workload Identity
        CsiDriverVersion = "1.4.0"
    }
}
