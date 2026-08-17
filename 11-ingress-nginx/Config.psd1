@{
    # DEPRECATED — kubernetes/ingress-nginx (this project) reaches End-of-Life
    # in March 2026: no further releases, bugfixes, or CVE patches afterwards.
    # See https://www.kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/
    # Traefik (11-ingress-traefik) is the default ingress controller now.
    # Kept only for existing deployments / explicit opt-in — do not build new
    # dependencies on this component.

    # Component metadata (NOT configurable by end user)
    Name            = "nginx-ingress"
    Version         = "4.15.1"
    Repository      = "https://kubernetes.github.io/ingress-nginx"
    ChartName       = "ingress-nginx"
    Namespace       = "ingress-nginx"
    RancherProject  = "Ingress"
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
