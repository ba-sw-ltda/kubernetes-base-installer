@{
    # Component metadata (NOT configurable by end user)
    Name            = "traefik"
    Version         = "39.0.8"
    Repository      = "https://traefik.github.io/charts"
    ChartName       = "traefik"
    Namespace       = "traefik"
    CreateNamespace = $true

    # User-configurable settings
    UserConfig = @{
        ServiceType    = "LoadBalancer"
        HostPortWeb    = 0
        HostPortSecure = 0
        MetalLbPool    = ""

        Resources = @{
            Limits   = @{ Cpu = "500m";  Memory = "512Mi" }
            Requests = @{ Cpu = "100m";  Memory = "128Mi" }
        }
    }
}
