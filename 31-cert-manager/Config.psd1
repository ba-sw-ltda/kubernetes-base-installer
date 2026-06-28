@{
    # Component metadata (NOT configurable by end user)
    Name            = "cert-manager"
    Version         = "v1.20.2"
    Repository      = "https://charts.jetstack.io"
    ChartName       = "cert-manager"
    Namespace       = "cert-manager"
    RancherProject  = "Security"
    CreateNamespace = $true

    # User-configurable settings
    UserConfig = @{
        InstallCRDs = $true

        Resources = @{
            Limits = @{
                Cpu    = "500m"
                Memory = "512Mi"
            }
            Requests = @{
                Cpu    = "100m"
                Memory = "128Mi"
            }
        }
    }
}
