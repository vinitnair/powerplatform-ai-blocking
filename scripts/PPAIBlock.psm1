#Requires -Version 7.0
<#
    PPAIBlock.psm1
    Power Platform AI blockade - core functions.

    Design note: this module deliberately leans on two different transports.

      * Enumeration and environment-level AI settings go through `pac`, because
        those paths were validated end-to-end in the lab.
      * Process deactivation and validation go through the Dataverse Web API,
        because `pac` has no data-write verb - there is no CLI path to set
        statecode on a workflow row.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The four Primary Entities whose processes constitute the AI control surface.
# Validated 28 Aug 2026: deactivating every process on these entities blocks all
# prebuilt models and Copilot Studio agent creation.
$script:AIEntityLogicalNames = @(
    'msdyn_aimodel'            # AI Model
    'msdyn_aiconfiguration'    # AI Configuration
    'bot'                      # Agent
    'botcomponentcollection'   # Agent component collection
)

# Processes that are AI controls but do NOT sit on the four entities above.
# Kept separate and conservative - only names confirmed present in a real org.
$script:SupplementalProcessNames = @('IsPaiEnabled')

$script:ApiVersion = 'v9.2'

# Resolved once per session by Resolve-PacPath. Must be initialised explicitly:
# Set-StrictMode throws on reads of a never-assigned variable.
$script:PacPath = $null

#region CLI resolution ---------------------------------------------------------

function Resolve-PacPath {
<#
.SYNOPSIS
    Returns a usable path to the Power Platform CLI, independent of PATHEXT.
.DESCRIPTION
    Bare-name resolution of 'pac' relies on PATHEXT containing '.EXE'. On
    hardened or misconfigured hosts PATHEXT is sometimes trimmed - seen in the
    wild reduced to '.CPL' - and PowerShell then refuses to launch pac.exe,
    reporting "Cannot run a document in the middle of a pipeline". That error
    names nothing relevant and costs an afternoon to diagnose, so normalise
    PATHEXT for this process only and fall back to the known install locations.
#>
    [CmdletBinding()]
    param()

    if ($script:PacPath -and (Test-Path $script:PacPath)) { return $script:PacPath }

    # Process-scoped only. Does not touch the user or machine environment.
    $required = @('.COM', '.EXE', '.BAT', '.CMD')
    $current  = @(($env:PATHEXT -split ';') | Where-Object { $_ })
    $missing  = @($required | Where-Object { $_ -notin $current })
    if ($missing.Count -gt 0) {
        $env:PATHEXT = (($current + $missing) | Select-Object -Unique) -join ';'
        Write-Verbose "PATHEXT was missing $($missing -join ', '); normalised for this process."
    }

    $cmd = Get-Command 'pac' -CommandType Application -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($cmd) { $script:PacPath = $cmd.Source; return $script:PacPath }

    $candidates = @(
        (Join-Path $env:USERPROFILE '.dotnet\tools\pac.exe')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerAppsCLI\pac.exe')
        (Join-Path ${env:ProgramFiles} 'Microsoft Power Platform CLI\pac.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { $script:PacPath = $c; return $script:PacPath }
    }

    throw "Power Platform CLI ('pac') not found. Install it with 'dotnet tool install --global Microsoft.PowerApps.CLI.Tool', or add its folder to PATH for the account running this script."
}

#endregion

#region Authentication ---------------------------------------------------------

function Get-PPAIToken {
<#
.SYNOPSIS
    Acquires an app-only token for a Dataverse organization.
.NOTES
    Client secret is accepted as a SecureString and never written to disk or logs.
    For production, prefer certificate auth - see README, "Hardening".
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][securestring]$ClientSecret,
        [Parameter(Mandatory)][string]$Resource
    )

    $plain = [System.Net.NetworkCredential]::new('', $ClientSecret).Password
    try {
        $body = @{
            client_id     = $ClientId
            client_secret = $plain
            scope         = ($Resource.TrimEnd('/') + '/.default')
            grant_type    = 'client_credentials'
        }
        $resp = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body $body -ContentType 'application/x-www-form-urlencoded'
    }
    finally {
        $plain = $null
        [System.GC]::Collect()
    }

    [pscustomobject]@{
        AccessToken = $resp.access_token
        ExpiresOn   = (Get-Date).AddSeconds([int]$resp.expires_in - 120)
        Resource    = $Resource
    }
}

#endregion

#region Dataverse transport ----------------------------------------------------

function Invoke-DvRequest {
<#
.SYNOPSIS
    Dataverse Web API call with service-protection-aware retry.
.DESCRIPTION
    Honours Retry-After on 429/503 and falls back to exponential backoff.
    At thousands of environments this is the difference between a run that
    completes and one that dies at hour three.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][object]$Token,
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [object]$Body,
        [int]$MaxAttempts = 6
    )

    $uri = "{0}/api/data/{1}/{2}" -f $BaseUrl.TrimEnd('/'), $script:ApiVersion, $Path
    $headers = @{
        Authorization      = "Bearer $($Token.AccessToken)"
        Accept             = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
        'If-None-Match'    = $null
    }

    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = $headers
    }
    if ($null -ne $Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 8 -Compress)
        $params.ContentType = 'application/json; charset=utf-8'
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod @params
        }
        catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }

            $retryable = $status -in @(429, 502, 503, 504)
            if (-not $retryable -or $attempt -eq $MaxAttempts) { throw }

            $delay = [Math]::Min([Math]::Pow(2, $attempt), 60)
            try {
                $ra = $_.Exception.Response.Headers.RetryAfter
                if ($ra -and $ra.Delta) { $delay = $ra.Delta.TotalSeconds }
            }
            catch { }

            Write-Verbose "HTTP $status on $Path - retry $attempt in ${delay}s"
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-DvObjectTypeCode {
<#
.SYNOPSIS
    Resolves a table's ObjectTypeCode at runtime.
.DESCRIPTION
    This must be resolved per environment, never hardcoded. Object type codes
    at or above 10000 are assigned per-organization, and `bot` /
    `botcomponentcollection` both live in that range - they were 10225 / 10227
    in the lab org but will differ elsewhere. Hardcoding them is a silent
    correctness bug that would skip the agent processes entirely.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][object]$Token,
        [Parameter(Mandatory)][string]$LogicalName
    )

    $path = "EntityDefinitions(LogicalName='$LogicalName')?`$select=ObjectTypeCode"
    try {
        $r = Invoke-DvRequest -BaseUrl $BaseUrl -Token $Token -Path $path
        return [int]$r.ObjectTypeCode
    }
    catch {
        Write-Verbose "Table '$LogicalName' not present in $BaseUrl - skipping"
        return $null
    }
}

#endregion

#region Inventory and enforcement ---------------------------------------------

function Get-AIProcessInventory {
<#
.SYNOPSIS
    Returns every AI-control process in an environment with its current state.
.OUTPUTS
    Objects with Name, PrimaryEntity, Type, StateCode, WorkflowId.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][object]$Token,
        [string[]]$AdditionalProcessNames = @()
    )

    $codes = foreach ($ln in $script:AIEntityLogicalNames) {
        $otc = Get-DvObjectTypeCode -BaseUrl $BaseUrl -Token $Token -LogicalName $ln
        if ($null -ne $otc) { $otc }
    }

    $names = $script:SupplementalProcessNames + $AdditionalProcessNames |
             Where-Object { $_ } | Select-Object -Unique

    $conditions = @()
    if ($codes.Count -gt 0) {
        $vals = ($codes | ForEach-Object { "<value>$_</value>" }) -join ''
        $conditions += "<condition attribute='primaryentity' operator='in'>$vals</condition>"
    }
    if ($names.Count -gt 0) {
        $vals = ($names | ForEach-Object { "<value>$([System.Security.SecurityElement]::Escape($_))</value>" }) -join ''
        $conditions += "<condition attribute='name' operator='in'>$vals</condition>"
    }
    if ($conditions.Count -eq 0) { return @() }

    # type=1 -> Definition. Activation records are children and follow the
    # Definition; targeting them directly is both unnecessary and unstable
    # (solution import deletes them, so counts drift).
    $fetch = @"
<fetch version='1.0' mapping='logical' count='500'>
  <entity name='workflow'>
    <attribute name='name' /><attribute name='primaryentity' />
    <attribute name='type' /><attribute name='statecode' />
    <filter type='and'>
      <condition attribute='type' operator='eq' value='1' />
      <filter type='or'>
        $($conditions -join '')
      </filter>
    </filter>
    <order attribute='name' />
  </entity>
</fetch>
"@

    $encoded = [uri]::EscapeDataString($fetch)
    $resp = Invoke-DvRequest -BaseUrl $BaseUrl -Token $Token -Path "workflows?fetchXml=$encoded"

    foreach ($w in $resp.value) {
        [pscustomobject]@{
            Name          = $w.name
            PrimaryEntity = $w.primaryentity
            Type          = $w.type
            StateCode     = $w.statecode          # 0 = Draft, 1 = Activated
            State         = if ($w.statecode -eq 0) { 'Draft' } else { 'Activated' }
            WorkflowId    = $w.workflowid
        }
    }
}

function Set-AIProcessState {
<#
.SYNOPSIS
    Deactivates (Draft) or reactivates (Activated) a single process.
.NOTES
    Idempotent by design - the caller filters to processes already in the
    wrong state, so a re-run over an enforced tenant issues zero writes.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][object]$Token,
        [Parameter(Mandatory)][string]$WorkflowId,
        [Parameter(Mandatory)][ValidateSet('Draft', 'Activated')][string]$State
    )

    $body = if ($State -eq 'Draft') { @{ statecode = 0; statuscode = 1 } }
            else                    { @{ statecode = 1; statuscode = 2 } }

    if ($PSCmdlet.ShouldProcess("workflow $WorkflowId", "set state to $State")) {
        Invoke-DvRequest -BaseUrl $BaseUrl -Token $Token `
            -Method 'PATCH' -Path "workflows($WorkflowId)" -Body $body | Out-Null
    }
}

function Test-AIBlockCompliance {
<#
.SYNOPSIS
    Read-only compliance assertion for one environment. This produces the
    evidence artefact - date it and keep it.
.DESCRIPTION
    Asserts on Definition statecode, never on record count. Activation child
    records are deleted during solution import, so counts legitimately drift
    while the block remains fully intact.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][object]$Token,
        [string]$EnvironmentId,
        [string]$DisplayName,
        [string[]]$AdditionalProcessNames = @()
    )

    $inv = @(Get-AIProcessInventory -BaseUrl $BaseUrl -Token $Token `
                -AdditionalProcessNames $AdditionalProcessNames)
    $active = @($inv | Where-Object StateCode -eq 1)

    [pscustomobject]@{
        Timestamp        = (Get-Date).ToString('o')
        EnvironmentId    = $EnvironmentId
        DisplayName      = $DisplayName
        EnvironmentUrl   = $BaseUrl
        ProcessesFound   = $inv.Count
        ProcessesDraft   = ($inv.Count - $active.Count)
        ProcessesActive  = $active.Count
        Compliant        = ($inv.Count -gt 0 -and $active.Count -eq 0)
        ActiveProcesses  = ($active.Name -join '; ')
    }
}

#endregion

#region Environment enumeration -----------------------------------------------

function Get-PPEnvironmentInventory {
<#
.SYNOPSIS
    Enumerates tenant environments via pac (verified path) and applies red-zone selection.
.PARAMETER GroupName
    Select by environment group - the recommended selector at enterprise scale.
.PARAMETER NamePattern
    Regex fallback where environment groups are not yet in place.
.PARAMETER EnvironmentIdFile
    Explicit allowlist of environment IDs, one per line. Highest precedence.
#>
    [CmdletBinding()]
    param(
        [string]$GroupName,
        [string]$NamePattern,
        [string]$EnvironmentIdFile
    )

    # Fail loud, never quiet. Every guard below exists because the failure mode
    # of this function is an empty list, and an empty list makes Audit report
    # "all compliant" and Enforce do nothing - both silently, both green.
    $pac = Resolve-PacPath

    # $LASTEXITCODE is stale if the executable never launched, so it cannot be
    # the only check - it would still hold 0 from whatever ran before.
    $global:LASTEXITCODE = 0
    $raw = & $pac admin list --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "pac admin list failed (exit $LASTEXITCODE): $(($raw | Out-String).Trim())"
    }

    try   { $all = @($raw | ConvertFrom-Json) }
    catch { throw "pac admin list returned unparseable output. Is the CLI signed in? Run 'pac auth create'." }

    if ($all.Count -eq 0) {
        throw "pac admin list returned no environments. Expected at least one - check the signed-in account has Power Platform Administrator."
    }
    $tenantTotal = $all.Count

    # Environments without a Dataverse instance have no processes to deactivate.
    $all = @($all | Where-Object { $_.EnvironmentUrl })
    Write-Verbose "pac returned $tenantTotal environment(s); $($all.Count) are Dataverse-backed."

    $selected = $all
    $selector = 'all Dataverse-backed environments'

    if ($EnvironmentIdFile) {
        $allow = Get-Content -Path $EnvironmentIdFile |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $selected = @($all | Where-Object { $_.EnvironmentId -in $allow })
        $selector = "file '$EnvironmentIdFile' ($($allow.Count) id(s))"
    }
    elseif ($GroupName) {
        $selected = @($all | Where-Object { $_.GroupName -eq $GroupName })
        $selector = "group '$GroupName'"
    }
    elseif ($NamePattern) {
        $selected = @($all | Where-Object { $_.DisplayName -match $NamePattern })
        $selector = "name pattern '$NamePattern'"
    }

    # A selector that matches nothing is almost always a typo, not a genuinely
    # empty scope. Say so - do not let the caller mistake it for a clean tenant.
    if ($selected.Count -eq 0) {
        Write-Warning "Selector matched 0 of $($all.Count) environments: $selector. Check the selector before treating this as 'nothing to enforce'."
    }

    return $selected
}

#endregion

Export-ModuleMember -Function @(
    'Resolve-PacPath'
    'Get-PPAIToken'
    'Invoke-DvRequest'
    'Get-DvObjectTypeCode'
    'Get-AIProcessInventory'
    'Set-AIProcessState'
    'Test-AIBlockCompliance'
    'Get-PPEnvironmentInventory'
)
