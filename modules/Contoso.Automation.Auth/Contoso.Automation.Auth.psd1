@{
    RootModule        = 'Contoso.Automation.Auth.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Infrastructure Team'
    CompanyName       = 'Contoso'
    Copyright         = '(c) 2026 Contoso. All rights reserved.'
    Description       = 'Shared authentication module for Azure Automation runbooks. Provides standardized Managed Identity and certificate-based authentication for Azure, SharePoint, and Microsoft Graph.'

    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    RequiredModules   = @(
        @{ ModuleName = 'Az.Accounts'; ModuleVersion = '3.0.0' }
        @{ ModuleName = 'Az.KeyVault'; ModuleVersion = '6.0.0' }
    )

    FunctionsToExport = @(
        'Connect-ContosoAzure'
        'Connect-ContosoSharePoint'
        'Connect-ContosoSPOAdmin'
        'Connect-ContosoGraph'
        'Connect-ContosoExchange'
        'Get-ContosoKeyVaultSecret'
        'Get-ContosoKeyVaultCertificate'
        'Invoke-ContosoWithRetry'
        'Disconnect-ContosoAll'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Azure', 'Automation', 'Authentication', 'ManagedIdentity')
            ProjectUri = ''
        }
    }
}
