@{
    Name            = "loki"
    Version         = "6.55.0"
    Repository      = "https://grafana.github.io/helm-charts"
    ChartName       = "loki"
    Namespace       = "monitoring"
    RancherProject  = "Observability"
    CreateNamespace = $false

    UserConfig = @{
        Retention         = "14d"
        StorageSize       = "10Gi"
        DeploymentMode    = "SingleBinary"
        ReplicationFactor = 1
        AuthEnabled       = $false
        StorageType       = "filesystem"
        ChunksCacheEnabled  = $false
        ResultsCacheEnabled = $false
        GatewayEnabled    = $false

        Resources = @{
            Limits   = @{ Cpu = "1000m"; Memory = "1Gi" }
            Requests = @{ Cpu = "100m";  Memory = "256Mi" }
        }
    }
}
