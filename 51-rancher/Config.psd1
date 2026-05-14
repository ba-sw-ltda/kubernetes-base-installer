@{
    # Component metadata (NOT configurable by end user)
    Name            = "rancher"
    Version         = "2.14.1"
    Repository      = "https://releases.rancher.com/server-charts/stable"
    ChartName       = "rancher"
    Namespace       = "cattle-system"
    CreateNamespace = $true

    # User-configurable settings
    UserConfig = @{
        Replicas          = 1
        TlsSource         = "rancher"
        TlsExternal       = $true     # TLS always terminated at nginx ingress
        IngressClassName  = "nginx"
        Resources = @{
            Limits   = @{ Cpu = "1000m"; Memory = "1Gi"   }
            Requests = @{ Cpu = "250m";  Memory = "256Mi" }
        }
    }
}
