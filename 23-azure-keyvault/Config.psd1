@{
    Name      = "azure-keyvault"
    Namespace = "external-secrets"

    UserConfig = @{
        SkuName        = "standard"   # standard or premium
        SoftDeleteDays = 7
    }
}
