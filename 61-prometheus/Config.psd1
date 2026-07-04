@{
    Name             = "prometheus"
    Version          = "83.7.0"
    Repository       = "https://prometheus-community.github.io/helm-charts"
    ChartName        = "kube-prometheus-stack"
    Namespace        = "prometheus"
    RancherProject   = "Observability"
    CreateNamespace  = $true

    PortalTitle      = "Prometheus"
    PortalSubtitle   = "Metrics & Alerting"
    PortalIcon       = "logo.svg"

    UserConfig = @{
        # Primary: stop writing when size is reached (~85% of PVC to leave WAL headroom)
        # Secondary: hard time cap so stale data doesn't linger even if PVC stays under limit
        RetentionSize = "17GB"
        RetentionTime = "90d"
        StorageSize   = "20Gi"

        # Prometheus resource limits
        Resources = @{
            Limits   = @{ Cpu = "1000m"; Memory = "2Gi" }
            Requests = @{ Cpu = "250m";  Memory = "512Mi" }
        }

        # Alertmanager — disabled by default (no alerting config yet)
        AlertmanagerEnabled        = $false
        GrafanaEnabled             = $false
        RemoteWriteReceiverEnabled = $true
    }
}
