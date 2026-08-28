#Requires -Version 7.0
<#
.SYNOPSIS
    Applies and validates the Power Platform AI blockade across a large tenant.

.DESCRIPTION
    Two modes:
      Audit   - read-only. Produces the compliance evidence file. Safe anywhere,
                including production, and the mode you run on a schedule.
      Enforce - deactivates every AI-control process that is currently Activated.

    Built for thousands of environments: parallel across environments, sequential
    within one, checkpointed so a killed run resumes instead of restarting, and
    idempotent so a re-run over an enforced tenant issues zero writes.

.EXAMPLE
    # Everything from config.json - the normal way to run this
    .\Invoke-AIBlockade.ps1 -Mode Audit

.EXAMPLE
    # Override one setting for a single run; the rest still comes from config
    .\Invoke-AIBlockade.ps1 -Mode Enforce -ThrottleLimit 12

.EXAMPLE
    # No config file at all - pass everything explicitly
    .\Invoke-AIBlockade.ps1 -Mode Audit -TenantId <guid> -ClientId <guid> -GroupName 'RedZone-Financial'

.NOTES
    Prerequisite: the service principal must exist as an Application User with
    System Administrator in every target environment. See Bootstrap-AppUsers.ps1.

    The client secret is never a parameter. It is read from an environment
    variable so it cannot appear in a command line, a scheduled-task definition,
    or a shell history file.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Audit', 'Enforce')]
    [string]$Mode = 'Audit',

    # Every setting below can come from config.json instead. Anything passed
    # explicitly on the command line wins over the file.
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'),

    [string]$TenantId,
    [string]$ClientId,
    [string]$SecretEnvVar,

    [string]$GroupName,
    [string]$NamePattern,
    [string]$EnvironmentIdFile,

    [string[]]$AdditionalProcessNames,

    [int]$ThrottleLimit,
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'runs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Configuration ------------------------------------------------------------
# Resolution order for every setting: command-line parameter, then config.json,
# then a built-in default. A parameter you actually typed always wins, including
# when you typed the same value the file already had.

$bound = $PSBoundParameters

# StrictMode throws on reads of absent properties, so walk the object by hand
# rather than dotting into a key that may not be in the file.
function Get-Cfg {
    param($Object, [string]$Path)
    $node = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $node) { return $null }
        $property = $node.PSObject.Properties[$segment]
        if (-not $property) { return $null }
        $node = $property.Value
    }
    return $node
}

function Resolve-Setting {
    param([Parameter(Mandatory)][string]$Name, $ConfigValue, $Default = $null)
    if ($bound.ContainsKey($Name))                              { return $bound[$Name] }
    if ($null -ne $ConfigValue -and "$ConfigValue" -ne '')      { return $ConfigValue }
    return $Default
}

$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try   { $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
    catch { throw "Config file '$ConfigPath' is not valid JSON. $($_.Exception.Message)" }
}

$TenantId               =      Resolve-Setting 'TenantId'               (Get-Cfg $cfg 'tenantId')
$ClientId               =      Resolve-Setting 'ClientId'               (Get-Cfg $cfg 'clientId')
$SecretEnvVar           =      Resolve-Setting 'SecretEnvVar'           (Get-Cfg $cfg 'secretEnvVar') 'PPAI_CLIENT_SECRET'
$GroupName              =      Resolve-Setting 'GroupName'              (Get-Cfg $cfg 'selection.groupName')
$NamePattern            =      Resolve-Setting 'NamePattern'            (Get-Cfg $cfg 'selection.namePattern')
$EnvironmentIdFile      =      Resolve-Setting 'EnvironmentIdFile'      (Get-Cfg $cfg 'selection.environmentIdFile')
$ThrottleLimit          = [int](Resolve-Setting 'ThrottleLimit'          (Get-Cfg $cfg 'throttleLimit') 8)
$AdditionalProcessNames =    @(Resolve-Setting 'AdditionalProcessNames' (Get-Cfg $cfg 'additionalProcessNames') @())

foreach ($required in 'TenantId', 'ClientId') {
    $value = Get-Variable -Name $required -ValueOnly
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$required was not supplied. Pass -$required, or copy config.example.json to config.json and fill it in."
    }
    if ($value.StartsWith('<')) {
        throw "$required is still the placeholder from config.example.json. Put your own value in '$ConfigPath'."
    }
}

# Selecting nothing means selecting everything. Say so out loud.
if (-not $GroupName -and -not $NamePattern -and -not $EnvironmentIdFile) {
    Write-Warning 'No group, name pattern or environment ID file was supplied. This run targets EVERY Dataverse-backed environment in the tenant.'
}

$modulePath = Join-Path $PSScriptRoot 'PPAIBlock.psm1'
Import-Module $modulePath -Force

$secretPlain = [Environment]::GetEnvironmentVariable($SecretEnvVar)
if ([string]::IsNullOrWhiteSpace($secretPlain)) {
    throw "Environment variable '$SecretEnvVar' is not set. Set it from Key Vault before running."
}
$secret = ConvertTo-SecureString $secretPlain -AsPlainText -Force
$secretPlain = $null

$runId      = (Get-Date).ToString('yyyyMMdd-HHmmss')
$runDir     = Join-Path $OutputRoot $runId
$null       = New-Item -ItemType Directory -Path $runDir -Force
$checkpoint = Join-Path $OutputRoot 'checkpoint.json'
$evidence   = Join-Path $runDir 'compliance-evidence.csv'
$errorLog   = Join-Path $runDir 'errors.csv'

Write-Host "Mode         : $Mode"
Write-Host "Config       : $(if ($cfg) { $ConfigPath } else { 'none - using parameters and defaults' })"
Write-Host "Run          : $runId"
Write-Host "Evidence     : $evidence"

# --- Select targets -----------------------------------------------------------

$targets = Get-PPEnvironmentInventory -GroupName $GroupName `
                                      -NamePattern $NamePattern `
                                      -EnvironmentIdFile $EnvironmentIdFile

Write-Host "Environments : $($targets.Count) selected (Dataverse-backed)"
if ($targets.Count -eq 0) { Write-Warning 'Nothing to do.'; return }

# --- Resume from checkpoint ---------------------------------------------------

$done = @{}
if ((Test-Path $checkpoint) -and $Mode -eq 'Enforce') {
    foreach ($id in (Get-Content $checkpoint -Raw | ConvertFrom-Json)) { $done[$id] = $true }
    $skip = @($targets | Where-Object { $done.ContainsKey($_.EnvironmentId) }).Count
    if ($skip -gt 0) { Write-Host "Checkpoint   : skipping $skip already-enforced environment(s)" }
}

$queue = @($targets | Where-Object { -not $done.ContainsKey($_.EnvironmentId) })

# --- Fan out ------------------------------------------------------------------

$results = $queue | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    Import-Module $using:modulePath -Force

    $env      = $_
    $mode     = $using:Mode
    $extra    = $using:AdditionalProcessNames
    $rowStart = Get-Date

    try {
        $token = Get-PPAIToken -TenantId $using:TenantId `
                               -ClientId $using:ClientId `
                               -ClientSecret $using:secret `
                               -Resource $env.EnvironmentUrl

        $changed = 0
        if ($mode -eq 'Enforce') {
            $inv = @(Get-AIProcessInventory -BaseUrl $env.EnvironmentUrl -Token $token `
                        -AdditionalProcessNames $extra)

            # Idempotent: only touch what is actually Activated.
            foreach ($p in ($inv | Where-Object StateCode -eq 1)) {
                Set-AIProcessState -BaseUrl $env.EnvironmentUrl -Token $token `
                    -WorkflowId $p.WorkflowId -State 'Draft' -Confirm:$false
                $changed++
            }
        }

        $r = Test-AIBlockCompliance -BaseUrl $env.EnvironmentUrl -Token $token `
                -EnvironmentId $env.EnvironmentId -DisplayName $env.DisplayName `
                -AdditionalProcessNames $extra

        $r | Add-Member -NotePropertyName 'Mode'            -NotePropertyValue $mode -PassThru |
             Add-Member -NotePropertyName 'ProcessesChanged' -NotePropertyValue $changed -PassThru |
             Add-Member -NotePropertyName 'DurationSec'      -NotePropertyValue ([math]::Round(((Get-Date) - $rowStart).TotalSeconds, 1)) -PassThru |
             Add-Member -NotePropertyName 'Error'            -NotePropertyValue '' -PassThru
    }
    catch {
        [pscustomobject]@{
            Timestamp = (Get-Date).ToString('o'); EnvironmentId = $env.EnvironmentId
            DisplayName = $env.DisplayName; EnvironmentUrl = $env.EnvironmentUrl
            ProcessesFound = 0; ProcessesDraft = 0; ProcessesActive = 0
            Compliant = $false; ActiveProcesses = ''
            Mode = $mode; ProcessesChanged = 0
            DurationSec = [math]::Round(((Get-Date) - $rowStart).TotalSeconds, 1)
            Error = $_.Exception.Message
        }
    }
}

# --- Persist ------------------------------------------------------------------

$results | Sort-Object DisplayName | Export-Csv -Path $evidence -NoTypeInformation -Encoding utf8

$failed = @($results | Where-Object { $_.Error })
if ($failed.Count -gt 0) {
    $failed | Export-Csv -Path $errorLog -NoTypeInformation -Encoding utf8
}

if ($Mode -eq 'Enforce') {
    $ok = @($results | Where-Object { -not $_.Error -and $_.Compliant }).EnvironmentId
    $all = ($done.Keys + $ok) | Select-Object -Unique
    $all | ConvertTo-Json | Set-Content -Path $checkpoint -Encoding utf8
}

# --- Summary ------------------------------------------------------------------

$compliant = @($results | Where-Object Compliant).Count
$changedTotal = ($results | Measure-Object ProcessesChanged -Sum).Sum

Write-Host ''
Write-Host "Compliant    : $compliant / $($results.Count)"
Write-Host "Processes deactivated this run : $changedTotal"
Write-Host "Errors       : $($failed.Count)$(if ($failed.Count) { " -> $errorLog" })"

if ($failed.Count -gt 0) { exit 2 }
if ($compliant -ne $results.Count) { exit 1 }
exit 0
