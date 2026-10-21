<#
.SYNOPSIS
    Interactive migration of Sophos Central devices (servers or clients)
    from one tenant to another tenant.

.DESCRIPTION
    The script uses the official Sophos Central endpoint migration API:
      1. Choose the sign-in method:
           [1] Tenant API keys - one API credential each for the source and target tenant
           [2] Partner/organization API key - a single sign-in, tenants are picked from a list
      2. Choose whether to migrate servers or clients (or cancel)
      3. Migrate all devices or pick individual devices in a GUI list (Out-GridView)
      4. Start the migration (two-step handshake: target tenant -> source tenant)
      5. Poll the migration status and report the result per device

    Requirements:
      - Sophos Central API credentials (client ID / client secret):
        either per tenant (Sophos Central Admin -> Global Settings ->
        API Credentials Management) or a partner/organization credential.
      - Source and target tenant must be in the same data region
        (a requirement of the Sophos migration API).
      - Windows PowerShell 5.1 or PowerShell 7+ (for Out-GridView on PS7:
        module Microsoft.PowerShell.GraphicalTools; without it a console selection is used).

.EXAMPLE
    .\Sophos-DeviceMigration.ps1

.NOTES
    Version 2.0 - for the graphical user interface see Sophos-DeviceMigration-GUI.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ============================================================================
#  Helper functions
# ============================================================================

function Write-Info    { param([string]$Text) Write-Host $Text -ForegroundColor Cyan }
function Write-Ok      { param([string]$Text) Write-Host $Text -ForegroundColor Green }
function Write-Warn2   { param([string]$Text) Write-Host $Text -ForegroundColor Yellow }
function Write-Err     { param([string]$Text) Write-Host $Text -ForegroundColor Red }

function Read-Secret {
    param([string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

function Get-SophosToken {
    param([string]$Id, [string]$Secret)

    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $Id
        client_secret = $Secret
        scope         = 'token'
    }
    $resp = Invoke-RestMethod -Method Post -Uri 'https://id.sophos.com/api/v2/oauth2/token' `
        -ContentType 'application/x-www-form-urlencoded' -Body $body
    return $resp.access_token
}

function Get-SophosWhoAmI {
    param([string]$Token)
    return Invoke-RestMethod -Method Get -Uri 'https://api.central.sophos.com/whoami/v1' `
        -Headers @{ Authorization = "Bearer $Token" }
}

function Get-SophosTenants {
    <# Lists all tenants of a partner or organization (with pagination). #>
    param(
        [string]$Token,
        [ValidateSet('partner', 'organization')][string]$IdType,
        [string]$EntityId
    )

    $baseUri = if ($IdType -eq 'partner') {
        'https://api.central.sophos.com/partner/v1/tenants'
    } else {
        'https://api.central.sophos.com/organization/v1/tenants'
    }
    $headerName = if ($IdType -eq 'partner') { 'X-Partner-ID' } else { 'X-Organization-ID' }

    $tenants = @()
    $page = 1
    do {
        $uri  = "$baseUri`?pageTotal=true&pageSize=100&page=$page"
        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers @{
            Authorization = "Bearer $Token"
            $headerName   = $EntityId
        }
        $tenants += $resp.items
        $totalPages = if ($resp.pages.total) { [int]$resp.pages.total } else { 1 }
        $page++
    } while ($page -le $totalPages)

    return $tenants
}

function Connect-SophosTenant {
    <#
        Signs in with a tenant API key and returns the tenant context
        (token, tenant ID, API host, name).
    #>
    param([Parameter(Mandatory)][string]$Label)

    Write-Host ""
    Write-Info "--- Sign-in: $Label ---"
    $id     = Read-Host "  Client ID ($Label)"
    $secret = Read-Secret "  Client secret ($Label)"

    $token  = Get-SophosToken -Id $id -Secret $secret
    $whoami = Get-SophosWhoAmI -Token $token

    if ($whoami.idType -ne 'tenant') {
        throw "The API key for '$Label' is not a tenant key (type: $($whoami.idType)). Please use an API key of the respective tenant."
    }

    return [pscustomobject]@{
        Token      = $token
        TenantId   = $whoami.id
        ApiHost    = $whoami.apiHosts.dataRegion
        DataRegion = ''
        Name       = $Label
    }
}

function Get-SophosEndpoints {
    <# Lists the endpoints of a tenant, filtered by type (computer | server). #>
    param(
        [Parameter(Mandatory)]$Tenant,
        [ValidateSet('computer', 'server')][string]$Type
    )

    $endpoints = @()
    $nextKey = $null
    do {
        $uri = "$($Tenant.ApiHost)/endpoint/v1/endpoints?pageSize=500&type=$Type"
        if ($nextKey) { $uri += "&pageFromKey=$([uri]::EscapeDataString($nextKey))" }

        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers @{
            Authorization = "Bearer $($Tenant.Token)"
            'X-Tenant-ID' = $Tenant.TenantId
        }
        $endpoints += $resp.items
        $nextKey = $resp.pages.nextKey
    } while ($nextKey)

    return $endpoints
}

function Select-FromList {
    <#
        Selection from a list - preferably via GUI (Out-GridView),
        falls back to a console selection if no GUI is available.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string]$Title,
        [switch]$Multiple
    )

    $ogv = Get-Command Out-GridView -ErrorAction SilentlyContinue
    if ($ogv) {
        $mode = if ($Multiple) { 'Multiple' } else { 'Single' }
        return @($Items | Out-GridView -Title $Title -OutputMode $mode)
    }

    # ---- Console fallback ----
    Write-Warn2 "`nOut-GridView is not available - using console selection."
    Write-Host "`n$Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $label = if ($Items[$i].PSObject.Properties['Hostname']) { $Items[$i].Hostname }
                 elseif ($Items[$i].PSObject.Properties['Name']) { $Items[$i].Name }
                 else { $Items[$i].ToString() }
        Write-Host ("  [{0,3}] {1}" -f ($i + 1), $label)
    }
    $hint = if ($Multiple) { "comma-separated numbers (e.g. 1,3,5) or 'a' for all" } else { "a single number" }
    $answer = Read-Host "Selection ($hint, empty = cancel)"
    if ([string]::IsNullOrWhiteSpace($answer)) { return @() }
    if ($Multiple -and $answer.Trim() -eq 'a') { return @($Items) }

    $selected = @()
    foreach ($part in ($answer -split ',')) {
        $n = 0
        if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
            $selected += $Items[$n - 1]
        }
    }
    return @($selected)
}

# ============================================================================
#  1) Choose the sign-in method and sign in
# ============================================================================

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "   Sophos Central - device migration between tenants" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "How do you want to sign in?" -ForegroundColor Cyan
Write-Host "  [1] Tenant API keys (one API key each for the source and target tenant)"
Write-Host "  [2] Partner/organization API key (single sign-in, tenants picked from a list)"
Write-Host "  [3] Cancel"
$authChoice = Read-Host "Choice (1-3)"

$srcTenant = $null   # context: Token, TenantId, ApiHost, Name
$dstTenant = $null

switch ($authChoice) {

    # ---- Option 1: one API key per tenant ----
    '1' {
        try {
            $srcTenant = Connect-SophosTenant -Label "SOURCE tenant (devices are migrated from here)"
            Write-Ok "  Signed in to source tenant [$($srcTenant.TenantId)]"

            $dstTenant = Connect-SophosTenant -Label "TARGET tenant (devices are migrated to here)"
            Write-Ok "  Signed in to target tenant [$($dstTenant.TenantId)]"
        } catch {
            Write-Err "Sign-in failed: $($_.Exception.Message)"
            exit 1
        }

        if ($srcTenant.TenantId -eq $dstTenant.TenantId) {
            Write-Err "Source and target tenant are identical - please use two different tenants."
            exit 1
        }
        $srcTenant.Name = "Source tenant"
        $dstTenant.Name = "Target tenant"
    }

    # ---- Option 2: partner/organization sign-in with tenant selection ----
    '2' {
        $pId     = Read-Host "Partner/organization client ID"
        $pSecret = Read-Secret "Partner/organization client secret"

        Write-Info "Requesting access token..."
        try {
            $pToken = Get-SophosToken -Id $pId -Secret $pSecret
        } catch {
            Write-Err "Sign-in failed: $($_.Exception.Message)"
            exit 1
        }

        $whoami = Get-SophosWhoAmI -Token $pToken
        if ($whoami.idType -notin @('partner', 'organization')) {
            Write-Err "The API key is not a partner/organization key (type: $($whoami.idType))."
            Write-Err "For tenant API keys, please restart the script and choose option [1]."
            exit 1
        }
        Write-Ok "Signed in successfully ($($whoami.idType))."

        Write-Info "Loading tenant list..."
        $allTenants = Get-SophosTenants -Token $pToken -IdType $whoami.idType -EntityId $whoami.id |
            Where-Object { $_.apiHost } |
            Sort-Object name |
            Select-Object name, id, dataRegion, apiHost

        if (-not $allTenants) { Write-Err "No tenants found."; exit 1 }

        $srcPick = (Select-FromList -Items $allTenants -Title "Select SOURCE tenant (devices are migrated from here)") | Select-Object -First 1
        if (-not $srcPick) { Write-Warn2 "Cancelled."; exit 0 }

        $dstPick = (Select-FromList -Items ($allTenants | Where-Object { $_.id -ne $srcPick.id }) `
            -Title "Select TARGET tenant (devices are migrated to here)") | Select-Object -First 1
        if (-not $dstPick) { Write-Warn2 "Cancelled."; exit 0 }

        if ($srcPick.dataRegion -and $dstPick.dataRegion -and $srcPick.dataRegion -ne $dstPick.dataRegion) {
            Write-Err "Source and target tenant are in different data regions ($($srcPick.dataRegion) / $($dstPick.dataRegion))."
            Write-Err "The Sophos migration API only supports migrations within the same region."
            exit 1
        }

        $srcTenant = [pscustomobject]@{ Token = $pToken; TenantId = $srcPick.id; ApiHost = $srcPick.apiHost; Name = $srcPick.name }
        $dstTenant = [pscustomobject]@{ Token = $pToken; TenantId = $dstPick.id; ApiHost = $dstPick.apiHost; Name = $dstPick.name }
    }

    default { Write-Warn2 "Cancelled."; exit 0 }
}

Write-Host ""
Write-Ok "Source: $($srcTenant.Name)  [$($srcTenant.TenantId)]"
Write-Ok "Target: $($dstTenant.Name)  [$($dstTenant.TenantId)]"

if ($srcTenant.ApiHost -ne $dstTenant.ApiHost) {
    Write-Err "Source and target tenant are in different data regions ($($srcTenant.ApiHost) / $($dstTenant.ApiHost))."
    Write-Err "The Sophos migration API only supports migrations within the same region."
    exit 1
}

# ============================================================================
#  2) What should be migrated?
# ============================================================================

Write-Host ""
Write-Host "What do you want to migrate?" -ForegroundColor Cyan
Write-Host "  [1] Servers"
Write-Host "  [2] Clients (computers)"
Write-Host "  [3] Cancel"
$choice = Read-Host "Choice (1-3)"

switch ($choice) {
    '1' { $deviceType = 'server';   $deviceLabel = 'servers' }
    '2' { $deviceType = 'computer'; $deviceLabel = 'clients' }
    default { Write-Warn2 "Cancelled."; exit 0 }
}

# ============================================================================
#  3) Load and select devices (all or individually via GUI)
# ============================================================================

Write-Info "`nLoading $deviceLabel from source tenant '$($srcTenant.Name)'..."
$devices = Get-SophosEndpoints -Tenant $srcTenant -Type $deviceType

if (-not $devices -or $devices.Count -eq 0) {
    Write-Warn2 "No $deviceLabel found in the source tenant."
    exit 0
}
Write-Ok "$($devices.Count) $deviceLabel found."

$deviceView = $devices | ForEach-Object {
    [pscustomobject]@{
        Hostname    = $_.hostname
        Type        = $_.type
        OS          = $_.os.name
        'Last user' = $_.associatedPerson.viaLogin
        Health      = $_.health.overall
        'Last seen' = $_.lastSeenAt
        Id          = $_.id
    }
}

Write-Host ""
Write-Host "Which $deviceLabel do you want to migrate?" -ForegroundColor Cyan
Write-Host "  [1] ALL $deviceLabel ($($devices.Count))"
Write-Host "  [2] Select individually (GUI list)"
Write-Host "  [3] Cancel"
$scopeChoice = Read-Host "Choice (1-3)"

switch ($scopeChoice) {
    '1' { $selectedDevices = @($deviceView) }
    '2' {
        $selectedDevices = Select-FromList -Items $deviceView -Multiple `
            -Title "$deviceLabel in tenant '$($srcTenant.Name)' - select the devices to migrate (Ctrl/Shift for multiple)"
    }
    default { Write-Warn2 "Cancelled."; exit 0 }
}

if (-not $selectedDevices -or $selectedDevices.Count -eq 0) {
    Write-Warn2 "No devices selected - aborting."
    exit 0
}

Write-Host ""
Write-Info "The following $($selectedDevices.Count) device(s) will be migrated:"
$selectedDevices | ForEach-Object { Write-Host "  - $($_.Hostname)" }

Write-Host ""
$confirm = Read-Host "Start migration from '$($srcTenant.Name)' to '$($dstTenant.Name)' now? (y/n)"
if ($confirm -notin @('y', 'Y', 'yes', 'Yes', 'j', 'J')) {
    Write-Warn2 "Cancelled."
    exit 0
}

$endpointIds = @($selectedDevices | ForEach-Object { $_.Id })

# ============================================================================
#  4) Start the migration (two-step handshake)
# ============================================================================

# Step 1: create the migration job in the TARGET tenant (returns job ID + token)
Write-Info "`n[1/2] Creating migration job in the target tenant..."
$createBody = @{ fromTenant = $srcTenant.TenantId; endpoints = $endpointIds } | ConvertTo-Json -Depth 4
try {
    $job = Invoke-RestMethod -Method Post -Uri "$($dstTenant.ApiHost)/endpoint/v1/migrations" `
        -Headers @{ Authorization = "Bearer $($dstTenant.Token)"; 'X-Tenant-ID' = $dstTenant.TenantId } `
        -ContentType 'application/json' -Body $createBody
} catch {
    Write-Err "Failed to create the migration job in the target tenant: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Err $_.ErrorDetails.Message }
    exit 1
}
Write-Ok "Migration job created (ID: $($job.id))."

# Step 2: confirm/start the migration in the SOURCE tenant
Write-Info "[2/2] Starting migration in the source tenant..."
$startBody = @{ token = $job.token; endpoints = $endpointIds } | ConvertTo-Json -Depth 4
try {
    $start = Invoke-RestMethod -Method Put -Uri "$($srcTenant.ApiHost)/endpoint/v1/migrations/$($job.id)" `
        -Headers @{ Authorization = "Bearer $($srcTenant.Token)"; 'X-Tenant-ID' = $srcTenant.TenantId } `
        -ContentType 'application/json' -Body $startBody
} catch {
    Write-Err "Failed to start the migration in the source tenant: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Err $_.ErrorDetails.Message }
    exit 1
}
Write-Ok "Migration started. The devices pick up the job at their next check-in."

# ============================================================================
#  5) Status per device (polling)
# ============================================================================

$hostnameById = @{}
foreach ($d in $selectedDevices) { $hostnameById[$d.Id] = $d.Hostname }

# Final states according to the Sophos API; everything else counts as "in progress"
$terminalStates = @('succeeded', 'failed')
$pollIntervalSec = 30
$maxWaitMinutes  = 30
$deadline = (Get-Date).AddMinutes($maxWaitMinutes)

Write-Host ""
Write-Info "Polling migration status (every $pollIntervalSec seconds, max. $maxWaitMinutes minutes)..."
Write-Warn2 "Note: offline devices stay 'pending' until they check in the next time."
Write-Warn2 "You can stop the script at any time with Ctrl+C - the migration continues on the server side."

$lastStatus = @{}
while ($true) {
    Start-Sleep -Seconds 5
    try {
        $statusResp = Invoke-RestMethod -Method Get `
            -Uri "$($srcTenant.ApiHost)/endpoint/v1/migrations/$($job.id)/endpoints?pageSize=500" `
            -Headers @{ Authorization = "Bearer $($srcTenant.Token)"; 'X-Tenant-ID' = $srcTenant.TenantId }
    } catch {
        Write-Warn2 "Status request failed: $($_.Exception.Message) - retrying..."
        Start-Sleep -Seconds $pollIntervalSec
        continue
    }

    $items = @($statusResp.items)
    $pendingCount = 0

    foreach ($item in $items) {
        $name   = if ($hostnameById.ContainsKey($item.id)) { $hostnameById[$item.id] } else { $item.id }
        $status = "$($item.status)"

        # Only print a line when the status changes
        if ($lastStatus[$item.id] -ne $status) {
            $lastStatus[$item.id] = $status
            switch -Regex ($status) {
                '^succeeded$' { Write-Ok   ("  [OK]      {0}  ->  migrated successfully" -f $name) }
                '^failed$'    { Write-Err  ("  [FAILED]  {0}  ->  migration failed" -f $name) }
                default       { Write-Info ("  [STATUS]  {0}  ->  {1}" -f $name, $status) }
            }
        }
        if ($status -notin $terminalStates) { $pendingCount++ }
    }

    if ($items.Count -gt 0 -and $pendingCount -eq 0) {
        break
    }
    if ((Get-Date) -gt $deadline) {
        Write-Warn2 "`nTime limit reached - $pendingCount device(s) have not finished yet."
        Write-Warn2 "The migration continues on the server side (devices are migrated at their next check-in)."
        break
    }
    Start-Sleep -Seconds ($pollIntervalSec - 5)
}

# ============================================================================
#  Summary
# ============================================================================

Write-Host ""
Write-Host "====================== RESULT ======================" -ForegroundColor Cyan
$ok     = @($lastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'succeeded' })
$failed = @($lastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'failed' })
$open   = @($lastStatus.GetEnumerator() | Where-Object { $_.Value -notin $terminalStates })

Write-Ok    ("  Migrated successfully: {0}" -f $ok.Count)
Write-Err   ("  Failed:                {0}" -f $failed.Count)
Write-Warn2 ("  Still pending:         {0}" -f $open.Count)

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Err "Failed devices:"
    foreach ($f in $failed) {
        $name = if ($hostnameById.ContainsKey($f.Key)) { $hostnameById[$f.Key] } else { $f.Key }
        Write-Err "  - $name"
    }
}
if ($open.Count -gt 0) {
    Write-Host ""
    Write-Warn2 "Pending devices (probably offline - they are migrated at their next check-in):"
    foreach ($o in $open) {
        $name = if ($hostnameById.ContainsKey($o.Key)) { $hostnameById[$o.Key] } else { $o.Key }
        Write-Warn2 "  - $name"
    }
}

Write-Host ""
Write-Ok "Done. Migration job ID: $($job.id)"
