@{
    # Component metadata (NOT configurable by end user)
    Name            = "nginx-ingress"
    Version         = "4.15.1"
    Repository      = "https://kubernetes.github.io/ingress-nginx"
    ChartName       = "ingress-nginx"
    Namespace       = "ingress-nginx"
    CreateNamespace = $true

    # User-configurable settings
    UserConfig = @{
        ReplicaCount     = 2
        ServiceType      = "LoadBalancer"
        HostPortEnabled  = $false
        MetalLbPool      = ""

        Resources = @{
            Limits   = @{ Cpu = "500m";  Memory = "512Mi" }
            Requests = @{ Cpu = "250m";  Memory = "256Mi" }
        }
    }
}
