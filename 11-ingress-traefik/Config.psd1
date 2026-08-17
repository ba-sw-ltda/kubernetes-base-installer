@{
    # Component metadata (NOT configurable by end user)
    Name            = "traefik"
    Version         = "39.0.8"
    Repository      = "https://traefik.github.io/charts"
    ChartName       = "traefik"
    # Shared with 11-ingress-nginx on purpose: both controllers are alternative
    # backends for the same "ingress" role, matching the 33-* secret-backend
    # pattern (33-azure-keyvault/aws-secretsmanager/gcp-secretmanager all share
    # "kube-system"). Neither Uninstall.ps1 deletes the namespace — only the
    # Helm release — so switching controllers keeps this namespace's
    # NetworkPolicy baseline, provider-ingress rule, and consumer labels intact
    # instead of rebuilding them from scratch on every switch.
    Namespace       = "ingress"
    RancherProject  = "Ingress"
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
