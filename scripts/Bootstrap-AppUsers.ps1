#Requires -Version 7.0
<#
.SYNOPSIS
    Seeds the automation service principal as an Application User in every target environment.

.DESCRIPTION
    This is the real prerequisite, and at enterprise scale it is the hard part - not
    the blockade itself. A Dataverse app-only token is scoped to one organization,
    and it is only issued if that organization contains an Application User for
    the app. Tenant-level admin rights do not substitute for this.

    Run this once per environment, and again for newly created environments.
    It is idempotent: environments that already have the app user are skipped.

.EXAMPLE
    pac auth create --name ppadmin       # sign in as Power Platform Administrator
    .\Bootstrap-AppUsers.ps1 -AppName 'PP-AIBlockade' -GroupName 'RedZone-Financial'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$AppName,
    [string]$GroupName,
    [string]$NamePattern,
    [string]$EnvironmentIdFile,
    [string]$Role = 'System Administrator',
    [string]$LogPath = (Join-Path $PSScriptRoot 'bootstrap-log.csv')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PPAIBlock.psm1') -Force

$pac = Resolve-PacPath

$targets = Get-PPEnvironmentInventory -GroupName $GroupName `
                                      -NamePattern $NamePattern `
                                      -EnvironmentIdFile $EnvironmentIdFile

Write-Host "Environments to bootstrap: $($targets.Count)"

$log = foreach ($env in $targets) {
    $start = Get-Date

    if (-not $PSCmdlet.ShouldProcess($env.DisplayName, "add app user '$AppName' with '$Role'")) {
        continue
    }

    # Sequential on purpose. This calls Entra plus Dataverse provisioning per
    # environment; running it wide triggers tenant-level throttling that is far
    # more painful to recover from than a slow run.
    $global:LASTEXITCODE = 0
    $out = & $pac admin create-service-principal `
                --environment $env.EnvironmentUrl `
                --name $AppName `
                --role $Role 2>&1

    $ok = ($LASTEXITCODE -eq 0)
    if ($ok) { Write-Host "  OK    $($env.DisplayName)" }
    else     { Write-Warning "  FAIL  $($env.DisplayName)" }

    [pscustomobject]@{
        Timestamp      = (Get-Date).ToString('o')
        EnvironmentId  = $env.EnvironmentId
        DisplayName    = $env.DisplayName
        EnvironmentUrl = $env.EnvironmentUrl
        Succeeded      = $ok
        DurationSec    = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
        Detail         = ($out | Out-String).Trim()
    }
}

$log | Export-Csv -Path $LogPath -NoTypeInformation -Encoding utf8

$failed = @($log | Where-Object { -not $_.Succeeded }).Count
Write-Host ''
Write-Host "Bootstrapped : $($log.Count - $failed) / $($log.Count)"
Write-Host "Log          : $LogPath"
if ($failed -gt 0) { exit 1 }
