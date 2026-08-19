@{
    # Magalu Cloud's block-storage CSI (block.csi.magalu.cloud) rejects any
    # volume smaller than 10Gi ("Input should be greater than or equal to
    # 10", size given in GiB) — the generic 5Gi default in Config.psd1 fails
    # provisioning outright on this platform.
    UserConfig = @{
        StorageSize = "10Gi"
    }
}
