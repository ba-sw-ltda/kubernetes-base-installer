@{
    # Longhorn's iSCSI attach mechanism has a known issue on Kind's nested
    # container architecture (nsenter resolves to a containerd-shim instead
    # of a real host PID — longhorn/longhorn#5693 territory; confirmed live:
    # volumes sit in "attaching"/unknown robustness forever, never reaching
    # the underlying iscsid). RKE2 nodes are real hosts and don't hit this —
    # Longhorn already works fine there for every other component's PVCs.
    # 'standard' (local-path-provisioner) is what OpenBao/Prometheus already
    # use successfully on this same Kind cluster, so MinIO follows suit here.
    UserConfig = @{
        StorageClass = "standard"
    }
}
