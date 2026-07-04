@{
    Name            = "opentelemetry-collector"
    Version         = "0.152.0"
    Repository      = "https://open-telemetry.github.io/opentelemetry-helm-charts"
    ChartName       = "opentelemetry-collector"
    Namespace       = "opentelemetry"
    RancherProject  = "Observability"
    CreateNamespace = $false

    UserConfig = @{
        # contrib includes loki + prometheusremotewrite exporters
        ImageRepository = "otel/opentelemetry-collector-contrib"
        Mode            = "deployment"

        PrometheusRemoteWriteUrl = "http://prometheus.prometheus:9090/api/v1/write"
        LokiOtlpUrl              = "http://loki.loki:3100/otlp"

        Resources = @{
            Limits   = @{ Cpu = "500m"; Memory = "512Mi" }
            Requests = @{ Cpu = "100m"; Memory = "128Mi" }
        }
    }
}
