@{
    # Component metadata (NOT configurable by end user)
    Name            = "longhorn"
    Version         = "1.11.1"
    Repository      = "https://charts.longhorn.io"
    ChartName       = "longhorn"
    Namespace       = "longhorn-system"
    CreateNamespace = $true

    # User-configurable settings
    UserConfig = @{
        # Number of replicas per volume — should match node count (max 3)
        ReplicaCount = 3
    }
}
