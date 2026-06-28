@{
    Name            = "authelia"
    Version         = "0.11.6"
    Repository      = "https://charts.authelia.com"
    ChartName       = "authelia"
    Namespace       = "authelia"
    RancherProject  = "Security"
    CreateNamespace = $true

    UserConfig = @{
        StorageSize  = "100Mi"
        StorageClass = ""   # empty = cluster default StorageClass

        Resources = @{
            Limits   = @{ Cpu = "300m"; Memory = "256Mi" }
            Requests = @{ Cpu = "50m";  Memory = "64Mi" }
        }
    }
}
