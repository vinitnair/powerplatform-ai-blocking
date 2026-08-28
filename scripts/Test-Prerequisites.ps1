#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-flight check. Run this before the first large enforcement run.

.DESCRIPTION
    Verifies the things that fail slowly and confusingly at scale:
      * the CLI resolves and is signed in
      * environment enumeration works and the selector matches what you expect
      * the app-only token is issued for a sample environment
      * the AI tables exist and their object type codes resolve at runtime
      * the compliance query returns a plausible process set

    Read-only throughout. Safe against production.

.EXAMPLE
    $env:PPAI_CLIENT_SECRET = '...'
    .\Test-Prerequisites.ps1 -TenantId <guid> -ClientId <guid> -GroupName 'RedZone-Financial'
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$ClientId,
    [string]$SecretEnvVar = 'PPAI_CLIENT_SECRET',
    [string]$GroupName,
    [string]$NamePattern,
    [string]$EnvironmentIdFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PPAIBlock.psm1') -Force

$fail = 0
function Step([string]$Name, [scriptblock]$Body) {
    Write-Host ''
    Write-Host "== $Name"
    try { & $Body; Write-Host '   PASS' -ForegroundColor Green }
    catch { Write-Host "   FAIL  $($_.Exception.Message)" -ForegroundColor Red; $script:fail++ }
}

Step 'Power Platform CLI' {
    $p = Resolve-PacPath -Verbose
    Write-Host "   $p"
}

$targets = @()
Step 'Environment enumeration and selector' {
    $script:targets = @(Get-PPEnvironmentInventory -GroupName $GroupName `
                            -NamePattern $NamePattern -EnvironmentIdFile $EnvironmentIdFile)
    Write-Host "   $($script:targets.Count) environment(s) selected"
    $script:targets | Select-Object -First 5 DisplayName, GroupName, Type |
        Format-Table -AutoSize | Out-String | Write-Host
    if ($script:targets.Count -eq 0) { throw 'Selector matched nothing - fix it before enforcing.' }
}

if (-not $TenantId -or -not $ClientId) {
    Write-Host ''
    Write-Host 'Skipping token and Dataverse checks: -TenantId / -ClientId not supplied.'
    Write-Host "Result: $(if ($fail) { "$fail failure(s)" } else { 'CLI and enumeration OK' })"
    exit ([int]($fail -gt 0))
}

$secretPlain = [Environment]::GetEnvironmentVariable($SecretEnvVar)
if ([string]::IsNullOrWhiteSpace($secretPlain)) {
    Write-Host ''
    Write-Host "Skipping token and Dataverse checks: `$env:$SecretEnvVar is not set."
    exit ([int]($fail -gt 0))
}
$secret = ConvertTo-SecureString $secretPlain -AsPlainText -Force
$secretPlain = $null

$sample = $targets[0]
$token  = $null

Step "App-only token for '$($sample.DisplayName)'" {
    $script:token = Get-PPAIToken -TenantId $TenantId -ClientId $ClientId `
                        -ClientSecret $secret -Resource $sample.EnvironmentUrl
    Write-Host "   token valid until $($script:token.ExpiresOn)"
}

Step 'Object type codes resolve at runtime' {
    foreach ($ln in @('msdyn_aimodel', 'msdyn_aiconfiguration', 'bot', 'botcomponentcollection')) {
        $otc = Get-DvObjectTypeCode -BaseUrl $sample.EnvironmentUrl -Token $script:token -LogicalName $ln
        if ($null -eq $otc) { Write-Host "   $ln : not present (will be skipped)" }
        else                { Write-Host "   $ln : $otc" }
    }
}

Step 'Compliance query' {
    $r = Test-AIBlockCompliance -BaseUrl $sample.EnvironmentUrl -Token $script:token `
             -EnvironmentId $sample.EnvironmentId -DisplayName $sample.DisplayName
    Write-Host "   found $($r.ProcessesFound), draft $($r.ProcessesDraft), active $($r.ProcessesActive), compliant $($r.Compliant)"
    if ($r.ProcessesFound -eq 0) {
        throw 'Zero processes found. Either the app user lacks read on workflow, or the AI tables are absent.'
    }
}

Write-Host ''
Write-Host "Result: $(if ($fail) { "$fail failure(s)" } else { 'all checks passed' })"
exit ([int]($fail -gt 0))
