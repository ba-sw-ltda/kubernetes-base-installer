@{
    Name            = "openbao"
    Version         = "0.27.2"
    Repository      = "https://openbao.github.io/openbao-helm"
    ChartName       = "openbao"
    Namespace       = "openbao"
    RancherProject  = "Security"
    CreateNamespace = $true

    UserConfig = @{
        StorageSize      = "5Gi"
        StorageClass     = ""         # always use cluster default StorageClass
        SecretsPath      = "secret"   # KV-v2 mount path

        Resources = @{
            Limits   = @{ Cpu = "500m"; Memory = "256Mi" }
            Requests = @{ Cpu = "100m"; Memory = "128Mi" }
        }
    }
}
