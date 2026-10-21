<#
.SYNOPSIS
    Interaktive Migration von Sophos Central Geräten (Server oder Clients)
    von einem Tenant auf einen anderen Tenant.

.DESCRIPTION
    Das Skript nutzt die offizielle Sophos Central Endpoint-Migration-API:
      1. Auswahl der Anmeldeart:
           [1] Tenant-API-Keys - je ein API-Credential für Quell- und Ziel-Tenant
           [2] Partner-/Organisations-API-Key - ein Login, Tenant-Auswahl per GUI
      2. Abfrage: Server oder Clients migrieren (oder abbrechen)
      3. Abfrage: alle Geräte oder einzelne Geräte per GUI (Out-GridView) auswählen
      4. Migration starten (Zwei-Schritt-Handshake: Ziel-Tenant -> Quell-Tenant)
      5. Status-Polling mit Rückmeldung pro Gerät

    Voraussetzungen:
      - Sophos Central API-Credentials (Client-ID / Client-Secret):
        entweder pro Tenant (Sophos Central Admin -> Globale Einstellungen ->
        API-Anmeldeinformationen) oder als Partner-/Organisations-Credential.
      - Quell- und Ziel-Tenant müssen in derselben Datenregion liegen
        (Voraussetzung der Sophos-Migration-API).
      - Windows PowerShell 5.1 oder PowerShell 7+ (für Out-GridView unter PS7:
        Modul Microsoft.PowerShell.GraphicalTools; ohne GUI gibt es einen Konsolen-Fallback).

.EXAMPLE
    .\Sophos-DeviceMigration.ps1

.NOTES
    Version 2.0 - grafische Oberfläche: siehe Sophos-DeviceMigration-GUI.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ============================================================================
#  Hilfsfunktionen
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
    <# Listet alle Tenants eines Partners bzw. einer Organisation auf (mit Paginierung). #>
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
        Meldet sich mit einem Tenant-API-Key an und liefert den Tenant-Kontext
        (Token, Tenant-ID, API-Host, Name) zurück.
    #>
    param([Parameter(Mandatory)][string]$Label)

    Write-Host ""
    Write-Info "--- Anmeldung $Label ---"
    $id     = Read-Host "  Client-ID ($Label)"
    $secret = Read-Secret "  Client-Secret ($Label)"

    $token  = Get-SophosToken -Id $id -Secret $secret
    $whoami = Get-SophosWhoAmI -Token $token

    if ($whoami.idType -ne 'tenant') {
        throw "Der angegebene API-Key für '$Label' ist kein Tenant-Key (Typ: $($whoami.idType)). Bitte einen API-Key des jeweiligen Tenants verwenden."
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
    <# Listet Endpoints eines Tenants, gefiltert nach Typ (computer | server). #>
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
        Auswahl aus einer Liste – bevorzugt per GUI (Out-GridView),
        Fallback auf Konsolen-Auswahl, falls keine GUI verfügbar ist.
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

    # ---- Konsolen-Fallback ----
    Write-Warn2 "`nOut-GridView ist nicht verfügbar – Konsolen-Auswahl wird verwendet."
    Write-Host "`n$Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $label = if ($Items[$i].PSObject.Properties['Hostname']) { $Items[$i].Hostname }
                 elseif ($Items[$i].PSObject.Properties['Name']) { $Items[$i].Name }
                 else { $Items[$i].ToString() }
        Write-Host ("  [{0,3}] {1}" -f ($i + 1), $label)
    }
    $hint = if ($Multiple) { "Nummern kommagetrennt (z.B. 1,3,5) oder 'a' für alle" } else { "eine Nummer" }
    $answer = Read-Host "Auswahl ($hint, leer = abbrechen)"
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
#  1) Anmeldeart wählen und anmelden
# ============================================================================

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "   Sophos Central - Geräte-Migration zwischen Tenants" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Wie möchtest du dich anmelden?" -ForegroundColor Cyan
Write-Host "  [1] Tenant-API-Keys (je ein API-Key für Quell- und Ziel-Tenant)"
Write-Host "  [2] Partner-/Organisations-API-Key (ein Login, Tenant-Auswahl per Liste)"
Write-Host "  [3] Abbrechen"
$authChoice = Read-Host "Auswahl (1-3)"

$srcTenant = $null   # Kontext: Token, TenantId, ApiHost, Name
$dstTenant = $null

switch ($authChoice) {

    # ---- Variante 1: eigene API-Keys pro Tenant ----
    '1' {
        try {
            $srcTenant = Connect-SophosTenant -Label "QUELL-Tenant (von dort werden Geräte migriert)"
            Write-Ok "  Angemeldet am Quell-Tenant [$($srcTenant.TenantId)]"

            $dstTenant = Connect-SophosTenant -Label "ZIEL-Tenant (dorthin werden Geräte migriert)"
            Write-Ok "  Angemeldet am Ziel-Tenant [$($dstTenant.TenantId)]"
        } catch {
            Write-Err "Anmeldung fehlgeschlagen: $($_.Exception.Message)"
            exit 1
        }

        if ($srcTenant.TenantId -eq $dstTenant.TenantId) {
            Write-Err "Quell- und Ziel-Tenant sind identisch - bitte unterschiedliche Tenants verwenden."
            exit 1
        }
        $srcTenant.Name = "Quell-Tenant"
        $dstTenant.Name = "Ziel-Tenant"
    }

    # ---- Variante 2: Partner-/Organisations-Login mit Tenant-Auswahl ----
    '2' {
        $pId     = Read-Host "Partner-/Organisations Client-ID"
        $pSecret = Read-Secret "Partner-/Organisations Client-Secret"

        Write-Info "Hole Access-Token..."
        try {
            $pToken = Get-SophosToken -Id $pId -Secret $pSecret
        } catch {
            Write-Err "Anmeldung fehlgeschlagen: $($_.Exception.Message)"
            exit 1
        }

        $whoami = Get-SophosWhoAmI -Token $pToken
        if ($whoami.idType -notin @('partner', 'organization')) {
            Write-Err "Der API-Key ist kein Partner-/Organisations-Key (Typ: $($whoami.idType))."
            Write-Err "Für Tenant-API-Keys bitte das Skript neu starten und Variante [1] wählen."
            exit 1
        }
        Write-Ok "Anmeldung erfolgreich ($($whoami.idType))."

        Write-Info "Lade Tenant-Liste..."
        $allTenants = Get-SophosTenants -Token $pToken -IdType $whoami.idType -EntityId $whoami.id |
            Where-Object { $_.apiHost } |
            Sort-Object name |
            Select-Object name, id, dataRegion, apiHost

        if (-not $allTenants) { Write-Err "Keine Tenants gefunden."; exit 1 }

        $srcPick = (Select-FromList -Items $allTenants -Title "QUELL-Tenant auswählen (von dort werden Geräte migriert)") | Select-Object -First 1
        if (-not $srcPick) { Write-Warn2 "Abgebrochen."; exit 0 }

        $dstPick = (Select-FromList -Items ($allTenants | Where-Object { $_.id -ne $srcPick.id }) `
            -Title "ZIEL-Tenant auswählen (dorthin werden Geräte migriert)") | Select-Object -First 1
        if (-not $dstPick) { Write-Warn2 "Abgebrochen."; exit 0 }

        if ($srcPick.dataRegion -and $dstPick.dataRegion -and $srcPick.dataRegion -ne $dstPick.dataRegion) {
            Write-Err "Quell- und Ziel-Tenant liegen in unterschiedlichen Datenregionen ($($srcPick.dataRegion) / $($dstPick.dataRegion))."
            Write-Err "Die Sophos-Migration-API unterstützt nur Migrationen innerhalb derselben Region."
            exit 1
        }

        $srcTenant = [pscustomobject]@{ Token = $pToken; TenantId = $srcPick.id; ApiHost = $srcPick.apiHost; Name = $srcPick.name }
        $dstTenant = [pscustomobject]@{ Token = $pToken; TenantId = $dstPick.id; ApiHost = $dstPick.apiHost; Name = $dstPick.name }
    }

    default { Write-Warn2 "Abgebrochen."; exit 0 }
}

Write-Host ""
Write-Ok "Quelle: $($srcTenant.Name)  [$($srcTenant.TenantId)]"
Write-Ok "Ziel:   $($dstTenant.Name)  [$($dstTenant.TenantId)]"

if ($srcTenant.ApiHost -ne $dstTenant.ApiHost) {
    Write-Err "Quell- und Ziel-Tenant liegen in unterschiedlichen Datenregionen ($($srcTenant.ApiHost) / $($dstTenant.ApiHost))."
    Write-Err "Die Sophos-Migration-API unterstützt nur Migrationen innerhalb derselben Region."
    exit 1
}

# ============================================================================
#  2) Abfrage: Was soll migriert werden?
# ============================================================================

Write-Host ""
Write-Host "Was soll migriert werden?" -ForegroundColor Cyan
Write-Host "  [1] Server"
Write-Host "  [2] Clients (Computer)"
Write-Host "  [3] Abbrechen"
$choice = Read-Host "Auswahl (1-3)"

switch ($choice) {
    '1' { $deviceType = 'server';   $deviceLabel = 'Server'  }
    '2' { $deviceType = 'computer'; $deviceLabel = 'Clients' }
    default { Write-Warn2 "Abgebrochen."; exit 0 }
}

# ============================================================================
#  3) Geräte laden und auswählen (alle oder einzeln per GUI)
# ============================================================================

Write-Info "`nLade $deviceLabel aus Quell-Tenant '$($srcTenant.Name)'..."
$devices = Get-SophosEndpoints -Tenant $srcTenant -Type $deviceType

if (-not $devices -or $devices.Count -eq 0) {
    Write-Warn2 "Im Quell-Tenant wurden keine $deviceLabel gefunden."
    exit 0
}
Write-Ok "$($devices.Count) $deviceLabel gefunden."

$deviceView = $devices | ForEach-Object {
    [pscustomobject]@{
        Hostname       = $_.hostname
        Typ            = $_.type
        OS             = $_.os.name
        'Letzter User' = $_.associatedPerson.viaLogin
        Health         = $_.health.overall
        'Zuletzt online' = $_.lastSeenAt
        Id             = $_.id
    }
}

Write-Host ""
Write-Host "Wie sollen die $deviceLabel migriert werden?" -ForegroundColor Cyan
Write-Host "  [1] ALLE $deviceLabel migrieren ($($devices.Count) Stück)"
Write-Host "  [2] Einzeln auswählen (GUI-Liste)"
Write-Host "  [3] Abbrechen"
$scopeChoice = Read-Host "Auswahl (1-3)"

switch ($scopeChoice) {
    '1' { $selectedDevices = @($deviceView) }
    '2' {
        $selectedDevices = Select-FromList -Items $deviceView -Multiple `
            -Title "$deviceLabel im Tenant '$($srcTenant.Name)' - zu migrierende Geräte markieren (Strg/Shift für Mehrfachauswahl)"
    }
    default { Write-Warn2 "Abgebrochen."; exit 0 }
}

if (-not $selectedDevices -or $selectedDevices.Count -eq 0) {
    Write-Warn2 "Keine Geräte ausgewählt - Abbruch."
    exit 0
}

Write-Host ""
Write-Info "Folgende $($selectedDevices.Count) Geräte werden migriert:"
$selectedDevices | ForEach-Object { Write-Host "  - $($_.Hostname)" }

Write-Host ""
$confirm = Read-Host "Migration von '$($srcTenant.Name)' nach '$($dstTenant.Name)' jetzt starten? (j/n)"
if ($confirm -notin @('j', 'J', 'ja', 'Ja', 'y', 'Y')) {
    Write-Warn2 "Abgebrochen."
    exit 0
}

$endpointIds = @($selectedDevices | ForEach-Object { $_.Id })

# ============================================================================
#  4) Migration starten (Zwei-Schritt-Handshake)
# ============================================================================

# Schritt 1: Migrations-Job im ZIEL-Tenant anlegen (liefert Job-ID + Token)
Write-Info "`n[1/2] Erstelle Migrations-Job im Ziel-Tenant..."
$createBody = @{ fromTenant = $srcTenant.TenantId; endpoints = $endpointIds } | ConvertTo-Json -Depth 4
try {
    $job = Invoke-RestMethod -Method Post -Uri "$($dstTenant.ApiHost)/endpoint/v1/migrations" `
        -Headers @{ Authorization = "Bearer $($dstTenant.Token)"; 'X-Tenant-ID' = $dstTenant.TenantId } `
        -ContentType 'application/json' -Body $createBody
} catch {
    Write-Err "Fehler beim Anlegen des Migrations-Jobs im Ziel-Tenant: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Err $_.ErrorDetails.Message }
    exit 1
}
Write-Ok "Migrations-Job erstellt (ID: $($job.id))."

# Schritt 2: Migration im QUELL-Tenant bestätigen/starten
Write-Info "[2/2] Starte Migration im Quell-Tenant..."
$startBody = @{ token = $job.token; endpoints = $endpointIds } | ConvertTo-Json -Depth 4
try {
    $start = Invoke-RestMethod -Method Put -Uri "$($srcTenant.ApiHost)/endpoint/v1/migrations/$($job.id)" `
        -Headers @{ Authorization = "Bearer $($srcTenant.Token)"; 'X-Tenant-ID' = $srcTenant.TenantId } `
        -ContentType 'application/json' -Body $startBody
} catch {
    Write-Err "Fehler beim Starten der Migration im Quell-Tenant: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Err $_.ErrorDetails.Message }
    exit 1
}
Write-Ok "Migration gestartet. Die Geräte holen den Auftrag bei ihrem nächsten Check-in ab."

# ============================================================================
#  5) Status-Rückmeldung pro Gerät (Polling)
# ============================================================================

$hostnameById = @{}
foreach ($d in $selectedDevices) { $hostnameById[$d.Id] = $d.Hostname }

# Endstatus laut Sophos-API; alles andere gilt als "in Arbeit"
$terminalStates = @('succeeded', 'failed')
$pollIntervalSec = 30
$maxWaitMinutes  = 30
$deadline = (Get-Date).AddMinutes($maxWaitMinutes)

Write-Host ""
Write-Info "Frage Migrationsstatus ab (alle $pollIntervalSec Sekunden, max. $maxWaitMinutes Minuten)..."
Write-Warn2 "Hinweis: Geräte, die offline sind, verbleiben in 'pending', bis sie sich das nächste Mal melden."
Write-Warn2 "Das Skript kann jederzeit mit Strg+C beendet werden - die Migration läuft serverseitig weiter."

$lastStatus = @{}
while ($true) {
    Start-Sleep -Seconds 5
    try {
        $statusResp = Invoke-RestMethod -Method Get `
            -Uri "$($srcTenant.ApiHost)/endpoint/v1/migrations/$($job.id)/endpoints?pageSize=500" `
            -Headers @{ Authorization = "Bearer $($srcTenant.Token)"; 'X-Tenant-ID' = $srcTenant.TenantId }
    } catch {
        Write-Warn2 "Statusabfrage fehlgeschlagen: $($_.Exception.Message) - neuer Versuch..."
        Start-Sleep -Seconds $pollIntervalSec
        continue
    }

    $items = @($statusResp.items)
    $pendingCount = 0

    foreach ($item in $items) {
        $name   = if ($hostnameById.ContainsKey($item.id)) { $hostnameById[$item.id] } else { $item.id }
        $status = "$($item.status)"

        # Nur bei Statusänderung eine Zeile ausgeben
        if ($lastStatus[$item.id] -ne $status) {
            $lastStatus[$item.id] = $status
            switch -Regex ($status) {
                '^succeeded$' { Write-Ok   ("  [OK]      {0}  ->  erfolgreich migriert" -f $name) }
                '^failed$'    { Write-Err  ("  [FEHLER]  {0}  ->  Migration fehlgeschlagen" -f $name) }
                default       { Write-Info ("  [STATUS]  {0}  ->  {1}" -f $name, $status) }
            }
        }
        if ($status -notin $terminalStates) { $pendingCount++ }
    }

    if ($items.Count -gt 0 -and $pendingCount -eq 0) {
        break
    }
    if ((Get-Date) -gt $deadline) {
        Write-Warn2 "`nZeitlimit erreicht - $pendingCount Gerät(e) sind noch nicht abgeschlossen."
        Write-Warn2 "Die Migration läuft serverseitig weiter (Geräte melden sich beim nächsten Check-in)."
        break
    }
    Start-Sleep -Seconds ($pollIntervalSec - 5)
}

# ============================================================================
#  Zusammenfassung
# ============================================================================

Write-Host ""
Write-Host "===================== ERGEBNIS =====================" -ForegroundColor Cyan
$ok     = @($lastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'succeeded' })
$failed = @($lastStatus.GetEnumerator() | Where-Object { $_.Value -eq 'failed' })
$open   = @($lastStatus.GetEnumerator() | Where-Object { $_.Value -notin $terminalStates })

Write-Ok    ("  Erfolgreich migriert: {0}" -f $ok.Count)
Write-Err   ("  Fehlgeschlagen:       {0}" -f $failed.Count)
Write-Warn2 ("  Noch ausstehend:      {0}" -f $open.Count)

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Err "Fehlgeschlagene Geräte:"
    foreach ($f in $failed) {
        $name = if ($hostnameById.ContainsKey($f.Key)) { $hostnameById[$f.Key] } else { $f.Key }
        Write-Err "  - $name"
    }
}
if ($open.Count -gt 0) {
    Write-Host ""
    Write-Warn2 "Ausstehende Geräte (vermutlich offline - Migration erfolgt beim nächsten Check-in):"
    foreach ($o in $open) {
        $name = if ($hostnameById.ContainsKey($o.Key)) { $hostnameById[$o.Key] } else { $o.Key }
        Write-Warn2 "  - $name"
    }
}

Write-Host ""
Write-Ok "Fertig. Migrations-Job-ID: $($job.id)"
