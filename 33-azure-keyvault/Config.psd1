@{
    Name           = "azure-keyvault"
    Namespace      = "kube-system"
    RancherProject = "Security"

    UserConfig = @{
        SkuName        = "standard"   # standard or premium
        SoftDeleteDays = 7
    }
}
