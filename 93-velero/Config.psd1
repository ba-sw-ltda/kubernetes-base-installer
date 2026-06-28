@{
    Name            = "velero"
    Version         = "12.1.0"
    Repository      = "https://vmware-tanzu.github.io/helm-charts"
    ChartName       = "velero"
    Namespace       = "velero"
    RancherProject  = "Utilities"
    CreateNamespace = $true

    UserConfig = @{
        # Velero CSI support has been built into the core image since v1.14 —
        # only the object-storage plugin still ships as a separate initContainer.
        PluginImage        = "velero/velero-plugin-for-aws:v1.13.1"
        SnapshotterVersion = "v8.5.0"   # kubernetes-csi/external-snapshotter release tag (RKE2/Kind only)

        Resources = @{
            Limits   = @{ Cpu = "500m"; Memory = "512Mi" }
            Requests = @{ Cpu = "100m"; Memory = "128Mi" }
        }
    }
}
