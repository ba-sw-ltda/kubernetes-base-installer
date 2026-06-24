@{
    # Component metadata (NOT configurable by end user)
    Name            = "metallb"
    Version         = "0.15.3"
    Repository      = "https://metallb.github.io/metallb"
    ChartName       = "metallb"
    Namespace       = "metallb-system"
    RancherProject  = "Ingress"
    CreateNamespace = $true

    # User-configurable settings
    UserConfig = @{
        # Pool name used by the ingress controller (via metallb.universe.tf/address-pool annotation)
        IngressPoolName = "ingress-pool"

        # General-purpose pool name (Kind: auto-detected; RKE2: extend here when needed)
        PoolName = "default-pool"

        Resources = @{
            Limits = @{
                Cpu    = "200m"
                Memory = "256Mi"
            }
            Requests = @{
                Cpu    = "50m"
                Memory = "64Mi"
            }
        }
    }
}
