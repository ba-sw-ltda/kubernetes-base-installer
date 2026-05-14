@{
    Name            = "secrets-csi-driver"
    Version         = "1.4.8"
    Repository      = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
    ChartName       = "secrets-store-csi-driver"
    Namespace       = "kube-system"
    CreateNamespace = $false

    UserConfig = @{
        SyncSecret = $false    # no K8s Secrets — files only
        RotationPollInterval = "2m"
    }
}
