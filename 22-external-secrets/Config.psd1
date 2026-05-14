@{
    # Component metadata (NOT configurable by end user)
    Name            = "external-secrets"
    Version         = "2.3.0"
    Repository      = "https://charts.external-secrets.io"
    ChartName       = "external-secrets"
    Namespace       = "external-secrets"
    CreateNamespace = $true

    # User-configurable settings
    UserConfig = @{
        InstallCRDs = $true

        Resources = @{
            Limits   = @{ Cpu = "500m";  Memory = "512Mi" }
            Requests = @{ Cpu = "100m";  Memory = "128Mi" }
        }
    }
}
