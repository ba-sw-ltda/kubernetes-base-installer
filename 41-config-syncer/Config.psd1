@{
    # Component metadata (NOT configurable by end user)
    Name            = "reflector"
    Version         = "7.1.288"
    Repository      = "https://emberstack.github.io/helm-charts"
    ChartName       = "reflector"
    Namespace       = "kube-system"
    CreateNamespace = $false

    # User-configurable settings
    UserConfig = @{
        Resources = @{
            Limits   = @{ Cpu = "200m";  Memory = "256Mi" }
            Requests = @{ Cpu = "50m";   Memory = "64Mi"  }
        }
    }
}
