@{
    # Component metadata (NOT configurable by end user)
    Name            = "rancher"
    Version         = "2.14.1"
    Repository      = "https://releases.rancher.com/server-charts/stable"
    ChartName       = "rancher"
    Namespace       = "cattle-system"
    CreateNamespace = $true

    PortalTitle     = "Rancher by SuSe"
    PortalSubtitle  = "Cluster Management"
    PortalIcon      = "logo.svg"

    # User-configurable settings
    UserConfig = @{
        Replicas          = 1
        TlsSource         = "rancher"
        TlsExternal       = $true     # TLS always terminated at nginx ingress
        IngressClassName  = "nginx"
        Resources = @{
            Limits   = @{ Cpu = "2000m"; Memory = "2Gi"   }
            Requests = @{ Cpu = "500m";  Memory = "512Mi" }
        }
    }
}
