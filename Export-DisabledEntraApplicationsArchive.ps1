<#
.SYNOPSIS
  Exports disabled Entra applications and related Graph data into a JSON archive structure.

.DESCRIPTION
  Finds applications that are disabled at the app registration level and,
  optionally, applications whose related service principals are disabled.
  For each matching app, the script exports a full-fidelity JSON archive that
  preserves the raw Graph payload for the application plus related objects that
  matter for reference, review, and future recreation:

  - application object
  - application owners
  - federated identity credentials
  - related service principals
  - app role assignments
  - delegated grant relationships
  - synchronization jobs

  Storage design:
  - One JSON file per application for durable nested data preservation
  - One manifest CSV for quick filtering and spreadsheet review
  - One manifest JSON for machine-friendly indexing

  Note: existing client secret values and certificate private keys cannot be
  recovered from Microsoft Graph. The archive preserves credential metadata
  only (display names, key IDs, expiry, thumbprints where available).

.PARAMETER OutDir
  Output directory for the archive. Default: .\disabled-app-archive

.PARAMETER IncludeServicePrincipalDisabled
  Also archive apps whose application object is enabled but one or more related
  service principals are disabled.

.EXAMPLE
  .\Export-DisabledEntraApplicationsArchive.ps1

.EXAMPLE
  .\Export-DisabledEntraApplicationsArchive.ps1 -OutDir .\archives\2026-03-22

.EXAMPLE
  .\Export-DisabledEntraApplicationsArchive.ps1 -IncludeServicePrincipalDisabled
#>
param(
  [string]$OutDir = "",
  [switch]$IncludeServicePrincipalDisabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path -Path $PWD -ChildPath "disabled-app-archive"
}

function Get-AllGraphPages {
  param([string]$Uri)

  $results = @()

  do {
    $resp = Invoke-MgGraphRequest -Uri $Uri -Method GET
    if ($null -ne $resp.value) {
      $results += @($resp.value)
    }

    if ($resp -is [System.Collections.IDictionary]) {
      $Uri = $resp['@odata.nextLink']
    }
    else {
      $next = $resp.PSObject.Properties['@odata.nextLink']
      $Uri = if ($next) { $next.Value } else { $null }
    }
  } while ($Uri)

  return $results
}

function Get-Prop {
  param($obj, [string]$key)

  if ($null -eq $obj) { return $null }
  if ($obj -is [System.Collections.IDictionary]) { return $obj[$key] }

  $p = $obj.PSObject.Properties[$key]
  if ($p) { return $p.Value }
  return $null
}

function ConvertTo-SafeFolderName {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return "unnamed"
  }

  $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
  $safe = $Value
  foreach ($char in $invalidChars) {
    $safe = $safe.Replace([string]$char, "-")
  }

  $safe = ($safe -replace "\s+", " ").Trim()
  $safe = ($safe -replace "[\. ]+$", "")

  if ([string]::IsNullOrWhiteSpace($safe)) {
    return "unnamed"
  }

  return $safe
}

function Get-GraphItemOrNull {
  param([string]$Uri)

  try {
    return Invoke-MgGraphRequest -Uri $Uri -Method GET
  }
  catch {
    Write-Warning "Request failed: $Uri`n$($_.Exception.Message)"
    return $null
  }
}

function Get-GraphCollectionOrEmpty {
  param([string]$Uri)

  try {
    return @(Get-AllGraphPages -Uri $Uri)
  }
  catch {
    Write-Warning "Request failed: $Uri`n$($_.Exception.Message)"
    return @()
  }
}

function New-ArchiveMetadata {
  param(
    $ApplicationSummary,
    [array]$ServicePrincipals
  )

  $disabledSps = @($ServicePrincipals | Where-Object { (Get-Prop $_ 'isDisabled') -eq $true })

  return [pscustomobject]@{
    AppId                          = Get-Prop $ApplicationSummary 'appId'
    DisplayName                    = Get-Prop $ApplicationSummary 'displayName'
    ApplicationObjectId            = Get-Prop $ApplicationSummary 'id'
    ApplicationDisabled            = [bool](Get-Prop $ApplicationSummary 'isDisabled')
    ServicePrincipalCount          = @($ServicePrincipals).Count
    DisabledServicePrincipalCount  = $disabledSps.Count
    DeletedDateUtc                 = $null
    ExportReason                   = if ((Get-Prop $ApplicationSummary 'isDisabled') -eq $true) {
      'ApplicationDisabled'
    } elseif ($disabledSps.Count -gt 0) {
      'ServicePrincipalDisabled'
    } else {
      'Unspecified'
    }
  }
}

function Ensure-GraphConnection {
  param(
    [string]$TenantId,
    [string]$ClientId,
    [string]$Thumbprint
  )

  $existingContext = $null
  try {
    $existingContext = Get-MgContext
  }
  catch {
    $existingContext = $null
  }

  if ($existingContext -and -not [string]::IsNullOrWhiteSpace($existingContext.TenantId)) {
    Write-Host "Using existing Microsoft Graph connection for tenant $($existingContext.TenantId)" -ForegroundColor Cyan
    return $existingContext
  }

  if (-not [string]::IsNullOrWhiteSpace($TenantId) -and
      -not [string]::IsNullOrWhiteSpace($ClientId) -and
      -not [string]::IsNullOrWhiteSpace($Thumbprint)) {
    Write-Host "No existing Graph connection found. Connecting with app certificate auth..." -ForegroundColor Cyan
    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $Thumbprint -NoWelcome | Out-Null
    return Get-MgContext
  }

  Write-Host "No existing Graph connection found. Starting interactive Graph sign-in..." -ForegroundColor Cyan
  Connect-MgGraph -Scopes @(
    'Application.Read.All',
    'Directory.Read.All',
    'AppRoleAssignment.Read.All',
    'DelegatedPermissionGrant.Read.All',
    'Synchronization.Read.All'
  ) -NoWelcome | Out-Null

  return Get-MgContext
}

function New-ManifestRow {
  param(
    [string]$DisplayName,
    [string]$AppId,
    [string]$ApplicationObjectId,
    [bool]$ApplicationDisabled,
    [int]$ServicePrincipalCount,
    [int]$DisabledServicePrincipalCount,
    [string]$ExportReason,
    [string]$ArchivePath,
    [string]$DeletedDateUtc
  )

  return [pscustomobject]@{
    DisplayName                   = $DisplayName
    AppId                         = $AppId
    ApplicationObjectId           = $ApplicationObjectId
    ApplicationDisabled           = $ApplicationDisabled
    ServicePrincipalCount         = $ServicePrincipalCount
    DisabledServicePrincipalCount = $DisabledServicePrincipalCount
    ExportReason                  = $ExportReason
    DeletedDateUtc                = $DeletedDateUtc
    ArchivePath                   = $ArchivePath
  }
}

function Update-DeletedArchiveStamp {
  param(
    [string]$ArchiveFilePath,
    [datetime]$DeletedDateUtc
  )

  $archive = Get-Content -LiteralPath $ArchiveFilePath -Raw | ConvertFrom-Json -Depth 100

  if ($null -eq $archive.Metadata) {
    return $null
  }

  if ([string]::IsNullOrWhiteSpace([string]$archive.Metadata.DeletedDateUtc)) {
    $archive.Metadata | Add-Member -NotePropertyName DeletedDateUtc -NotePropertyValue $DeletedDateUtc.ToString("o") -Force
    $archive | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $ArchiveFilePath -Encoding UTF8
  }

  return $archive
}

function Get-ExistingDeletedArchiveRows {
  param(
    [string]$ArchiveRoot,
    [hashtable]$CurrentAppIds,
    [hashtable]$CurrentApplicationObjectIds
  )

  $rows = @()
  if (-not (Test-Path -LiteralPath $ArchiveRoot)) {
    return $rows
  }

  $archiveFiles = @(Get-ChildItem -Path $ArchiveRoot -Filter 'archive.json' -Recurse -File -ErrorAction SilentlyContinue)
  $deletedDateUtc = (Get-Date).ToUniversalTime()

  foreach ($archiveFile in $archiveFiles) {
    try {
      $archive = Get-Content -LiteralPath $archiveFile.FullName -Raw | ConvertFrom-Json -Depth 100
    }
    catch {
      Write-Warning "Could not read archive file '$($archiveFile.FullName)': $($_.Exception.Message)"
      continue
    }

    $metadata = $archive.Metadata
    if ($null -eq $metadata) {
      continue
    }

    $appId = [string]$metadata.AppId
    $appObjectId = [string]$metadata.ApplicationObjectId
    $appStillExists = $false

    if (-not [string]::IsNullOrWhiteSpace($appId) -and $CurrentAppIds.ContainsKey($appId)) {
      $appStillExists = $true
    }
    elseif (-not [string]::IsNullOrWhiteSpace($appObjectId) -and $CurrentApplicationObjectIds.ContainsKey($appObjectId)) {
      $appStillExists = $true
    }

    if ($appStillExists) {
      continue
    }

    $archive = Update-DeletedArchiveStamp -ArchiveFilePath $archiveFile.FullName -DeletedDateUtc $deletedDateUtc
    if ($null -eq $archive -or $null -eq $archive.Metadata) {
      continue
    }

    $rows += New-ManifestRow `
      -DisplayName ([string]$archive.Metadata.DisplayName) `
      -AppId ([string]$archive.Metadata.AppId) `
      -ApplicationObjectId ([string]$archive.Metadata.ApplicationObjectId) `
      -ApplicationDisabled ([bool]$archive.Metadata.ApplicationDisabled) `
      -ServicePrincipalCount ([int]$archive.Metadata.ServicePrincipalCount) `
      -DisabledServicePrincipalCount ([int]$archive.Metadata.DisabledServicePrincipalCount) `
      -ExportReason ([string]$archive.Metadata.ExportReason) `
      -ArchivePath $archiveFile.FullName `
      -DeletedDateUtc ([string]$archive.Metadata.DeletedDateUtc)
  }

  return $rows
}

# ------------------------------------------------------------
# Graph connection
# ------------------------------------------------------------

$TenantId   = ""
$ClientId   = ""
$Thumbprint = ""

$context = Ensure-GraphConnection -TenantId $TenantId -ClientId $ClientId -Thumbprint $Thumbprint
$tenantIdFromContext = if ($context) { $context.TenantId } else { $null }

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Write-Host "Fetching app registrations..." -ForegroundColor Cyan
$applications = @(Get-AllGraphPages "https://graph.microsoft.com/beta/applications?`$select=id,appId,displayName,isDisabled,createdDateTime,signInAudience&`$top=999")
Write-Host "  Applications: $($applications.Count)"

$currentAppIds = @{}
$currentApplicationObjectIds = @{}
foreach ($application in $applications) {
  $currentAppId = Get-Prop $application 'appId'
  $currentApplicationObjectId = Get-Prop $application 'id'

  if (-not [string]::IsNullOrWhiteSpace($currentAppId)) {
    $currentAppIds[[string]$currentAppId] = $true
  }
  if (-not [string]::IsNullOrWhiteSpace($currentApplicationObjectId)) {
    $currentApplicationObjectIds[[string]$currentApplicationObjectId] = $true
  }
}

Write-Host "Fetching service principals..." -ForegroundColor Cyan
$servicePrincipals = @(Get-AllGraphPages "https://graph.microsoft.com/beta/servicePrincipals?`$select=id,appId,displayName,isDisabled,servicePrincipalType,appOwnerOrganizationId&`$top=999")
Write-Host "  Service principals: $($servicePrincipals.Count)"

$servicePrincipalsByAppId = @{}
foreach ($sp in $servicePrincipals) {
  $appId = Get-Prop $sp 'appId'
  if ([string]::IsNullOrWhiteSpace($appId)) {
    continue
  }

  if (-not $servicePrincipalsByAppId.ContainsKey($appId)) {
    $servicePrincipalsByAppId[$appId] = New-Object System.Collections.ArrayList
  }
  [void]$servicePrincipalsByAppId[$appId].Add($sp)
}

$disabledApps = foreach ($app in $applications) {
  $appId = Get-Prop $app 'appId'
  $relatedServicePrincipals = if ($servicePrincipalsByAppId.ContainsKey($appId)) {
    @($servicePrincipalsByAppId[$appId])
  } else {
    @()
  }

  $appIsDisabled = (Get-Prop $app 'isDisabled') -eq $true
  $hasDisabledSp = @($relatedServicePrincipals | Where-Object { (Get-Prop $_ 'isDisabled') -eq $true }).Count -gt 0

  if ($appIsDisabled -or ($IncludeServicePrincipalDisabled -and $hasDisabledSp)) {
    $app
  }
}

$disabledApps = @($disabledApps | Sort-Object { Get-Prop $_ 'displayName' }, { Get-Prop $_ 'appId' })

Write-Host "Applications selected for archive: $($disabledApps.Count)" -ForegroundColor Yellow

$manifestRows = @()

$i = 0
foreach ($app in $disabledApps) {
  $i++
  $displayName = Get-Prop $app 'displayName'
  $appId = Get-Prop $app 'appId'
  $appObjectId = Get-Prop $app 'id'

  Write-Progress -Activity "Exporting disabled application archives" -Status "$i / $($disabledApps.Count): $displayName" -PercentComplete (($i / [Math]::Max($disabledApps.Count, 1)) * 100)

  $appFolderName = "{0}__{1}" -f (ConvertTo-SafeFolderName -Value $displayName), $appId
  $appFolderPath = Join-Path -Path $OutDir -ChildPath $appFolderName
  New-Item -ItemType Directory -Path $appFolderPath -Force | Out-Null

  $applicationRecord = Get-GraphItemOrNull -Uri "https://graph.microsoft.com/beta/applications/$appObjectId"
  $applicationOwners = Get-GraphCollectionOrEmpty -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId/owners?`$top=999"
  $federatedIdentityCredentials = Get-GraphCollectionOrEmpty -Uri "https://graph.microsoft.com/beta/applications/$appObjectId/federatedIdentityCredentials?`$top=999"

  $relatedServicePrincipals = if ($servicePrincipalsByAppId.ContainsKey($appId)) {
    @($servicePrincipalsByAppId[$appId])
  } else {
    @()
  }

  $servicePrincipalArchives = foreach ($spSummary in $relatedServicePrincipals) {
    $spId = Get-Prop $spSummary 'id'
    $servicePrincipalRecord = Get-GraphItemOrNull -Uri "https://graph.microsoft.com/beta/servicePrincipals/$spId"

    [pscustomobject]@{
      Summary                   = $spSummary
      ServicePrincipal          = $servicePrincipalRecord
      Owners                    = @(Get-GraphCollectionOrEmpty -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/owners?`$top=999")
      AppRoleAssignedTo         = @(Get-GraphCollectionOrEmpty -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo?`$top=999")
      AppRoleAssignments        = @(Get-GraphCollectionOrEmpty -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments?`$top=999")
      OAuth2PermissionGrantsAsClient   = @(Get-GraphCollectionOrEmpty -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$spId'")
      OAuth2PermissionGrantsAsResource = @(Get-GraphCollectionOrEmpty -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=resourceId eq '$spId'")
      SynchronizationJobs       = @(Get-GraphCollectionOrEmpty -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/synchronization/jobs?`$top=999")
    }
  }

  $archiveMetadata = New-ArchiveMetadata -ApplicationSummary $app -ServicePrincipals $relatedServicePrincipals
  $archiveObject = [pscustomobject]@{
    SchemaVersion = 1
    ExportedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    TenantId      = $tenantIdFromContext
    Notes         = @(
      "This archive preserves Graph-readable configuration for future reference or recreation."
      "Client secret values are not retrievable from Graph and are therefore not included."
      "Certificate private keys are not exported; only credential metadata available in Graph is preserved."
    )
    Metadata = $archiveMetadata
    Application = [pscustomobject]@{
      Summary                     = $app
      FullObject                  = $applicationRecord
      Owners                      = $applicationOwners
      FederatedIdentityCredentials = $federatedIdentityCredentials
    }
    RelatedServicePrincipals = $servicePrincipalArchives
  }

  $archiveFilePath = Join-Path -Path $appFolderPath -ChildPath "archive.json"
  $archiveObject | ConvertTo-Json -Depth 100 | Set-Content -Path $archiveFilePath -Encoding UTF8

  $manifestRows += New-ManifestRow `
    -DisplayName $displayName `
    -AppId $appId `
    -ApplicationObjectId $appObjectId `
    -ApplicationDisabled ([bool](Get-Prop $app 'isDisabled')) `
    -ServicePrincipalCount (@($relatedServicePrincipals).Count) `
    -DisabledServicePrincipalCount (@($relatedServicePrincipals | Where-Object { (Get-Prop $_ 'isDisabled') -eq $true }).Count) `
    -ExportReason $archiveMetadata.ExportReason `
    -ArchivePath $archiveFilePath `
    -DeletedDateUtc $null
}

Write-Progress -Activity "Exporting disabled application archives" -Completed

$deletedArchiveRows = @(Get-ExistingDeletedArchiveRows -ArchiveRoot $OutDir -CurrentAppIds $currentAppIds -CurrentApplicationObjectIds $currentApplicationObjectIds)
if ($deletedArchiveRows.Count -gt 0) {
  Write-Host "Previously archived apps no longer found in Graph: $($deletedArchiveRows.Count)" -ForegroundColor Yellow
}

$manifestRows = @($manifestRows + $deletedArchiveRows | Sort-Object DisplayName, AppId, DeletedDateUtc)

$manifestJsonPath = Join-Path -Path $OutDir -ChildPath "manifest.json"
$manifestCsvPath = Join-Path -Path $OutDir -ChildPath "manifest.csv"

$manifestDocument = [pscustomobject]@{
  SchemaVersion = 1
  ExportedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  TenantId      = $tenantIdFromContext
  ArchiveRoot   = (Resolve-Path -Path $OutDir).Path
  ApplicationCount = $manifestRows.Count
  IncludeServicePrincipalDisabled = [bool]$IncludeServicePrincipalDisabled
  Applications = $manifestRows
}

$manifestDocument | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestJsonPath -Encoding UTF8
$manifestRows | Export-Csv -Path $manifestCsvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Archive complete." -ForegroundColor Green
Write-Host "  Archive root : $((Resolve-Path -Path $OutDir).Path)"
Write-Host "  Manifest CSV : $manifestCsvPath"
Write-Host "  Manifest JSON: $manifestJsonPath"
Write-Host "  Apps archived: $($manifestRows.Count)"
