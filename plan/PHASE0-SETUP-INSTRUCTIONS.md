# Phase 0: Infrastructure Setup — Operator Instructions

## Overview

This phase prepares all infrastructure prerequisites before any runbook code is touched. Everything here is a one-time setup.

**Estimated time:** 1–2 hours.
**Who should run this:** Azure admin with Owner or User Access Administrator role on the Automation Account's resource group, plus Global Administrator or Privileged Role Administrator in Entra ID (for granting App Roles).

---

## Step 0.1: Enable System-Assigned Managed Identity

### Via Portal
1. Go to **Azure Portal** > **Automation Account** > **Identity**
2. Under **System assigned** tab, set Status to **On**
3. Click **Save**
4. **Record the Object ID** — you will need it for permission grants

### Via PowerShell
```powershell
Set-AzAutomationAccount -ResourceGroupName "<RG>" `
    -Name "<AA>" `
    -AssignSystemIdentity

# Get the Object ID
$aa = Get-AzAutomationAccount -ResourceGroupName "<RG>" -Name "<AA>"
$miObjectId = $aa.Identity.PrincipalId
Write-Output "Managed Identity Object ID: $miObjectId"
```

### Record This Value

| Property | Value |
|----------|-------|
| Managed Identity Object ID | `________________________` |
| Automation Account Name | `________________________` |
| Resource Group | `________________________` |
| Subscription | `________________________` |
| Tenant ID | `________________________` |

---

## Step 0.2: (Optional) Create User-Assigned Managed Identity

Only needed if multiple Automation Accounts must share the same identity, or if you need to decouple identity lifecycle from the Automation Account.

```powershell
# Create the User-Assigned MI
New-AzUserAssignedIdentity -ResourceGroupName "<RG>" `
    -Name "uami-automation-auth" `
    -Location "<region>"

# Get its Client ID and Object ID
$uami = Get-AzUserAssignedIdentity -ResourceGroupName "<RG>" -Name "uami-automation-auth"
Write-Output "Client ID: $($uami.ClientId)"
Write-Output "Object ID: $($uami.PrincipalId)"

# Assign to Automation Account
# Portal: Automation Account > Identity > User assigned > Add > select the UAMI
```

Skip this step if System-Assigned MI is sufficient.

---

## Step 0.3: Grant Entra ID App Roles to the Managed Identity

The Managed Identity needs application-level permissions for Microsoft Graph and SharePoint. There is no portal UI for this — it must be done via PowerShell.

### Using the Provided Script

```powershell
cd D:\DevProjects\AzureAuthUpdates

.\scripts\setup\Grant-ManagedIdentityPermissions.ps1 `
    -ManagedIdentityObjectId "<OBJECT-ID-FROM-STEP-0.1>" `
    -GrantSharePoint `
    -GrantGraph
```

This grants:
- **SharePoint:** `Sites.FullControl.All`
- **Graph:** `Sites.ReadWrite.All`, `User.Read.All`, `Group.Read.All`, `Mail.Send`

### Customize Permissions

If your runbooks need different Graph permissions, pass them explicitly:

```powershell
.\scripts\setup\Grant-ManagedIdentityPermissions.ps1 `
    -ManagedIdentityObjectId "<OBJECT-ID>" `
    -GrantGraph `
    -GraphPermissions @(
        "Sites.ReadWrite.All"
        "User.ReadWrite.All"
        "Group.ReadWrite.All"
        "Directory.Read.All"
        "Mail.Send"
    )
```

### Verify Permissions

After granting, verify in the portal:
1. **Entra ID** > **Enterprise Applications** > search for the Managed Identity name (same as Automation Account name)
2. Click it > **Permissions** > should list the granted App Roles

---

## Step 0.4: Create/Configure Azure Key Vault

### Create Key Vault (if it doesn't exist)

```powershell
New-AzKeyVault -ResourceGroupName "<RG>" `
    -Name "<VAULT-NAME>" `
    -Location "<region>" `
    -EnableRbacAuthorization $true    # Use RBAC, not access policies
```

### Grant Managed Identity Access

```powershell
$miObjectId = "<OBJECT-ID-FROM-STEP-0.1>"
$kvId = (Get-AzKeyVault -VaultName "<VAULT-NAME>").ResourceId

# Secrets access
New-AzRoleAssignment -ObjectId $miObjectId `
    -RoleDefinitionName "Key Vault Secrets User" `
    -Scope $kvId

# Certificate access (if using cert-based auth for any service)
New-AzRoleAssignment -ObjectId $miObjectId `
    -RoleDefinitionName "Key Vault Certificate User" `
    -Scope $kvId
```

### Upload Certificates (if needed)

If any runbooks need certificate-based auth (e.g., cross-tenant SPO access):

```powershell
# Import a PFX certificate
Import-AzKeyVaultCertificate -VaultName "<VAULT-NAME>" `
    -Name "SPOCert" `
    -FilePath "C:\path\to\cert.pfx" `
    -Password (Read-Host -AsSecureString "PFX password")
```

### Store Configuration Values

Store non-secret config that runbooks may need:

```powershell
# These are non-sensitive but centralized for convenience
Set-AzKeyVaultSecret -VaultName "<VAULT-NAME>" -Name "TenantId" `
    -SecretValue (ConvertTo-SecureString "<TENANT-ID>" -AsPlainText -Force)
Set-AzKeyVaultSecret -VaultName "<VAULT-NAME>" -Name "TenantName" `
    -SecretValue (ConvertTo-SecureString "contoso.onmicrosoft.com" -AsPlainText -Force)
```

---

## Step 0.5: Enable Key Vault Audit Logging

```powershell
$kvId = (Get-AzKeyVault -VaultName "<VAULT-NAME>").ResourceId

# Option A: Send to Log Analytics workspace
$workspaceId = (Get-AzOperationalInsightsWorkspace -ResourceGroupName "<RG>" -Name "<WORKSPACE>").ResourceId
Set-AzDiagnosticSetting -ResourceId $kvId `
    -Name "KeyVaultAudit" `
    -WorkspaceId $workspaceId `
    -Enabled $true `
    -Category AuditEvent

# Option B: Send to Storage Account (cheaper, for compliance archival)
$storageId = (Get-AzStorageAccount -ResourceGroupName "<RG>" -Name "<STORAGE>").Id
Set-AzDiagnosticSetting -ResourceId $kvId `
    -Name "KeyVaultAudit" `
    -StorageAccountId $storageId `
    -Enabled $true `
    -Category AuditEvent `
    -RetentionEnabled $true `
    -RetentionInDays 365
```

---

## Step 0.6: Create Custom Runtime Environment

### Using the Provided Script

```powershell
cd D:\DevProjects\AzureAuthUpdates

.\scripts\setup\New-RuntimeEnvironment.ps1 `
    -ResourceGroupName "<RG>" `
    -AutomationAccountName "<AA>"
```

This creates a `PS74-ModernAuth` runtime environment and queues installation of all required modules at pinned versions.

### Via Portal (if the script fails)

1. **Automation Account** > **Runtime Environments** > **Create**
2. Name: `PS74-ModernAuth`
3. Language: PowerShell
4. Runtime version: 7.4
5. After creation, go to **Modules** > **Add from gallery** for each:
   - `Az.Accounts` (3.x)
   - `Az.KeyVault` (6.x)
   - `PnP.PowerShell` (2.12+)
   - `Microsoft.Graph.Authentication` (2.x)
   - `Microsoft.Graph.Sites` (2.x)
   - `Microsoft.Graph.Users` (2.x)
   - `Microsoft.Graph.Groups` (2.x)

### Wait for Module Installation

Module installation is asynchronous. Check status:

```powershell
Get-AzAutomationModule -ResourceGroupName "<RG>" `
    -AutomationAccountName "<AA>" `
    -RuntimeEnvironment "PS74-ModernAuth" |
    Select-Object Name, ProvisioningState |
    Format-Table -AutoSize
```

All modules must show `Succeeded` before proceeding to Phase 1.

---

## Step 0.7: Deploy the Shared Auth Module

```powershell
cd D:\DevProjects\AzureAuthUpdates

.\scripts\setup\Deploy-AuthModule.ps1 `
    -ModulePath ".\modules\Contoso.Automation.Auth" `
    -ResourceGroupName "<RG>" `
    -AutomationAccountName "<AA>" `
    -RuntimeEnvironment "PS74-ModernAuth"
```

If no storage account is available, the script will provide manual upload instructions for the portal.

---

## Phase 0 Completion Checklist

```
[ ] System-Assigned Managed Identity enabled — Object ID recorded
[ ] (Optional) User-Assigned MI created and attached
[ ] MI granted SharePoint Sites.FullControl.All
[ ] MI granted required Microsoft Graph App Roles
[ ] Permissions verified in Entra ID > Enterprise Applications
[ ] Azure Key Vault created with RBAC authorization
[ ] MI granted Key Vault Secrets User + Certificate User roles
[ ] Certificates uploaded to Key Vault (if applicable)
[ ] Key Vault audit logging enabled
[ ] PS74-ModernAuth runtime environment created
[ ] All modules installed and showing "Succeeded"
[ ] Contoso.Automation.Auth module deployed to runtime environment
```

Once all items are checked, proceed to **Phase 1** (validate the shared auth module with `staging/Test-AuthModule.ps1`).
