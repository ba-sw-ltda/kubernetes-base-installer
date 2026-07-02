@{
    # Not a user-selectable component — installed as a dependency by
    # 93-velero/Install.ps1 on RKE2/Kind only (cloud platforms use their
    # native object storage instead). Still its own Config/Install pair so
    # it can be re-run standalone for debugging, same as every other
    # component in this repo.
    Name            = "minio"
    Version         = "5.4.0"
    Repository      = "https://charts.min.io/"
    ChartName       = "minio"
    Namespace       = "minio"
    RancherProject  = "Utilities"
    CreateNamespace = $true

    UserConfig = @{
        BucketName   = "velero-backups"
        StorageSize  = "15Gi"
        StorageClass = ""   # empty = cluster default StorageClass (Longhorn)

        Resources = @{
            Limits   = @{ Cpu = "500m"; Memory = "512Mi" }
            Requests = @{ Cpu = "100m"; Memory = "128Mi" }
        }
    }
}
