<#
.SYNOPSIS
    Grafische Oberfläche (WPF) für die Migration von Sophos Central Geräten
    (Server oder Clients) von einem Tenant auf einen anderen Tenant.

.DESCRIPTION
    Geführter Assistent in vier Schritten:
      1. Anmeldung - Tenant-API-Keys (Quell- und Ziel-Tenant) oder
         Partner-/Organisations-API-Key
      2. Tenant-Auswahl (nur bei Partner-/Organisations-Login)
      3. Geräte auswählen - Server oder Clients, mit Suche und Mehrfachauswahl
      4. Migration starten und Live-Status pro Gerät verfolgen,
         inkl. Protokoll und CSV-Export des Ergebnisses

    Alle API-Aufrufe laufen im Hintergrund, die Oberfläche bleibt bedienbar.
    Access-Tokens werden bei Bedarf automatisch erneuert.

    Voraussetzungen:
      - Windows mit Windows PowerShell 5.1 oder PowerShell 7+
      - Sophos Central API-Credentials (siehe README)
      - Quell- und Ziel-Tenant in derselben Datenregion

.EXAMPLE
    .\Sophos-DeviceMigration-GUI.ps1

.NOTES
    Version 2.0
#>

[CmdletBinding()]
param()

if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Error 'Die grafische Oberfläche benötigt Windows (WPF). Unter anderen Systemen bitte Sophos-DeviceMigration.ps1 verwenden.'
    exit 1
}

# WPF benötigt einen STA-Thread - ggf. neu starten
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-STA', '-File', "`"$PSCommandPath`"")
    exit 0
}

$script:AppVersion = '2.0'
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ============================================================================
#  Datenmodelle für die Oberfläche (mit Änderungsbenachrichtigung)
# ============================================================================

if (-not ('SophosDeviceItem' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;

public class SophosDeviceItem : INotifyPropertyChanged
{
    private bool _isSelected;
    private string _status;
    private string _statusText;

    public string Id { get; set; }
    public string Hostname { get; set; }
    public string OS { get; set; }
    public string LastUser { get; set; }
    public string Health { get; set; }
    public DateTime? LastSeen { get; set; }

    public bool IsSelected
    {
        get { return _isSelected; }
        set { if (_isSelected != value) { _isSelected = value; OnChanged("IsSelected"); } }
    }
    public string Status
    {
        get { return _status; }
        set { if (_status != value) { _status = value; OnChanged("Status"); } }
    }
    public string StatusText
    {
        get { return _statusText; }
        set { if (_statusText != value) { _statusText = value; OnChanged("StatusText"); } }
    }

    public event PropertyChangedEventHandler PropertyChanged;
    private void OnChanged(string name)
    {
        PropertyChangedEventHandler h = PropertyChanged;
        if (h != null) { h(this, new PropertyChangedEventArgs(name)); }
    }
}

public class SophosTenantItem
{
    public string Name { get; set; }
    public string Id { get; set; }
    public string DataRegion { get; set; }
    public string ApiHost { get; set; }
}
'@
}

# ============================================================================
#  Sophos-API-Funktionen (laufen auch in den Hintergrund-Runspaces)
# ============================================================================

function Invoke-SophosApi {
    param(
        [string]$Method = 'Get',
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        $Body,
        [string]$ContentType
    )
    $params = @{ Method = $Method; Uri = $Uri; ErrorAction = 'Stop' }
    if ($Headers)        { $params.Headers = $Headers }
    if ($null -ne $Body) { $params.Body = $Body }
    if ($ContentType)    { $params.ContentType = $ContentType }
    try {
        Invoke-RestMethod @params
    } catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $detail = $_.ErrorDetails.Message
            try {
                $json = $detail | ConvertFrom-Json
                if ($json.message) { $detail = $json.message }
                elseif ($json.error_description) { $detail = $json.error_description }
            } catch { }
            $msg += " - $detail"
        }
        throw $msg
    }
}

function New-SophosSession {
    <# Holt ein Access-Token und merkt sich die Credentials für eine spätere Erneuerung. #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Secret)

    $session = [pscustomobject]@{ ClientId = $Id; Secret = $Secret; Token = $null; Expires = [datetime]::MinValue }
    Update-SophosSession -Session $session -Force
    return $session
}

function Update-SophosSession {
    <# Erneuert das Token, wenn es in weniger als 5 Minuten abläuft. #>
    param([Parameter(Mandatory)]$Session, [switch]$Force)

    if (-not $Force -and (Get-Date) -lt $Session.Expires.AddMinutes(-5)) { return }

    $resp = Invoke-SophosApi -Method Post -Uri 'https://id.sophos.com/api/v2/oauth2/token' `
        -ContentType 'application/x-www-form-urlencoded' -Body @{
            grant_type    = 'client_credentials'
            client_id     = $Session.ClientId
            client_secret = $Session.Secret
            scope         = 'token'
        }
    $lifetime = if ($resp.expires_in) { [int]$resp.expires_in } else { 3600 }
    $Session.Token   = $resp.access_token
    $Session.Expires = (Get-Date).AddSeconds($lifetime)
}

function Get-SophosWhoAmI {
    param([Parameter(Mandatory)]$Session)
    Update-SophosSession -Session $Session
    return Invoke-SophosApi -Uri 'https://api.central.sophos.com/whoami/v1' `
        -Headers @{ Authorization = "Bearer $($Session.Token)" }
}

function Get-SophosTenants {
    <# Listet alle Tenants eines Partners bzw. einer Organisation auf (mit Paginierung). #>
    param(
        [Parameter(Mandatory)]$Session,
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
        Update-SophosSession -Session $Session
        $resp = Invoke-SophosApi -Uri "$baseUri`?pageTotal=true&pageSize=100&page=$page" -Headers @{
            Authorization = "Bearer $($Session.Token)"
            $headerName   = $EntityId
        }
        $tenants += $resp.items
        $totalPages = if ($resp.pages.total) { [int]$resp.pages.total } else { 1 }
        $page++
    } while ($page -le $totalPages)

    return $tenants
}

function Get-SophosTenantHeaders {
    param([Parameter(Mandatory)]$Tenant)
    Update-SophosSession -Session $Tenant.Session
    return @{ Authorization = "Bearer $($Tenant.Session.Token)"; 'X-Tenant-ID' = $Tenant.TenantId }
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
        $resp = Invoke-SophosApi -Uri $uri -Headers (Get-SophosTenantHeaders -Tenant $Tenant)
        $endpoints += $resp.items
        $nextKey = $resp.pages.nextKey
    } while ($nextKey)

    return $endpoints
}

function Get-SophosMigrationStatus {
    <# Liefert den Migrationsstatus je Gerät eines Migrations-Jobs. #>
    param([Parameter(Mandatory)]$Tenant, [Parameter(Mandatory)][string]$JobId)

    $items = @()
    $nextKey = $null
    do {
        $uri = "$($Tenant.ApiHost)/endpoint/v1/migrations/$JobId/endpoints?pageSize=500"
        if ($nextKey) { $uri += "&pageFromKey=$([uri]::EscapeDataString($nextKey))" }
        $resp = Invoke-SophosApi -Uri $uri -Headers (Get-SophosTenantHeaders -Tenant $Tenant)
        $items += $resp.items
        $nextKey = $resp.pages.nextKey
    } while ($nextKey)

    return $items
}

function Get-RegionFromApiHost {
    param([string]$ApiHost)
    if ($ApiHost -match 'api-([a-z0-9]+)\.') { return $Matches[1] }
    return ''
}

# ============================================================================
#  Hintergrund-Ausführung (hält die Oberfläche reaktionsfähig)
# ============================================================================

$script:Iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($fn in 'Invoke-SophosApi', 'New-SophosSession', 'Update-SophosSession', 'Get-SophosWhoAmI',
                'Get-SophosTenants', 'Get-SophosTenantHeaders', 'Get-SophosEndpoints',
                'Get-SophosMigrationStatus', 'Get-RegionFromApiHost') {
    $script:Iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $fn, (Get-Command $fn).Definition))
}
$script:Iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'ErrorActionPreference', 'Stop', ''))

$script:BgTasks = New-Object System.Collections.ArrayList

function Start-BgTask {
    <#
        Führt $Work in einem eigenen Runspace aus. $OnSuccess erhält das erste
        Ausgabeobjekt, $OnError den Fehlertext - beide laufen im UI-Thread.
        Mit -BusyText wird währenddessen das Warte-Overlay angezeigt.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Work,
        [hashtable]$Arguments = @{},
        [scriptblock]$OnSuccess,
        [scriptblock]$OnError,
        [string]$BusyText
    )

    $rs = [runspacefactory]::CreateRunspace($script:Iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Work.ToString()).AddParameters($Arguments)

    $task = [pscustomobject]@{
        PS        = $ps
        Handle    = $ps.BeginInvoke()
        OnSuccess = $OnSuccess
        OnError   = $OnError
        Busy      = [bool]$BusyText
    }
    [void]$script:BgTasks.Add($task)
    if ($BusyText) { Show-Busy $BusyText }
    if (-not $script:BgTimer.IsEnabled) { $script:BgTimer.Start() }
}

function Get-ErrorText {
    param($Exception)
    $e = $Exception
    while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
    return $e.Message
}

$script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:BgTimer.Add_Tick({
    foreach ($task in @($script:BgTasks)) {
        if (-not $task.Handle.IsCompleted) { continue }
        $script:BgTasks.Remove($task)

        $result = $null
        $err = $null
        try {
            $output = $task.PS.EndInvoke($task.Handle)
            if ($output.Count -gt 0) { $result = $output[0] }
        } catch {
            $err = Get-ErrorText $_.Exception
        } finally {
            $task.PS.Runspace.Dispose()
            $task.PS.Dispose()
        }

        if (-not @($script:BgTasks | Where-Object { $_.Busy }).Count) { Hide-Busy }

        try {
            if ($err) { if ($task.OnError) { & $task.OnError $err } }
            elseif ($task.OnSuccess) { & $task.OnSuccess $result }
        } catch {
            Show-Error "Unerwarteter Fehler:`n$($_.Exception.Message)"
        }
    }
    if ($script:BgTasks.Count -eq 0) { $script:BgTimer.Stop() }
})

# ============================================================================
#  Oberfläche (XAML)
# ============================================================================

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Sophos Central – Geräte-Migration" Width="1200" Height="800" MinWidth="1000" MinHeight="680"
        WindowStartupLocation="CenterScreen" Background="#F3F5F9" FontFamily="Segoe UI" FontSize="13"
        Foreground="#1B2430" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Primary" Color="#0067D8"/>
    <SolidColorBrush x:Key="PrimaryDark" Color="#0052AD"/>
    <SolidColorBrush x:Key="Navy" Color="#0B1F3A"/>
    <SolidColorBrush x:Key="Line" Color="#DDE3EC"/>
    <SolidColorBrush x:Key="Muted" Color="#5F6B7A"/>
    <SolidColorBrush x:Key="Success" Color="#1E9E5A"/>
    <SolidColorBrush x:Key="Danger" Color="#D64545"/>
    <SolidColorBrush x:Key="Warning" Color="#C98400"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="20"/>
    </Style>

    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="22"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,4,0,20"/>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Margin" Value="0,14,0,6"/>
    </Style>
    <Style x:Key="Overline" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    </Style>

    <!-- Buttons -->
    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Foreground" Value="#1B2430"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#EEF3FA"/>
          <Setter Property="BorderBrush" Value="#B9CCE6"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="{StaticResource Primary}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Primary}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Padding" Value="20,9"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{StaticResource PrimaryDark}"/>
          <Setter Property="BorderBrush" Value="{StaticResource PrimaryDark}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Eingabefelder -->
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="9,7"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#CBD3DF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <Grid>
                <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
                <TextBlock x:Name="Placeholder" Text="{TemplateBinding Tag}" Foreground="#9AA5B4" IsHitTestVisible="False"
                           Margin="12,0,0,0" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value="">
                <Setter TargetName="Placeholder" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Primary}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Padding" Value="9,7"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#CBD3DF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="Bd" CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Primary}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Auswahl-Karten (Anmeldeart) -->
    <Style x:Key="OptionCard" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1.5" CornerRadius="10" Padding="16,14">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid Width="18" Height="18" VerticalAlignment="Top" Margin="0,2,12,0">
                  <Ellipse x:Name="Ring" Stroke="#9AA5B4" StrokeThickness="1.5"/>
                  <Ellipse x:Name="Dot" Fill="{StaticResource Primary}" Margin="4" Visibility="Collapsed"/>
                </Grid>
                <ContentPresenter Grid.Column="1"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#8DB8EE"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Primary}"/>
                <Setter TargetName="Bd" Property="Background" Value="#F2F7FE"/>
                <Setter TargetName="Ring" Property="Stroke" Value="{StaticResource Primary}"/>
                <Setter TargetName="Dot" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Segment-Umschalter (Server / Clients) -->
    <Style x:Key="Segment" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Padding="18,7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E8EEF6"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource Primary}"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Listen -->
    <Style TargetType="ListBox">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" CornerRadius="6" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F2F5F9"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E3EEFC"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Primary}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#EEF1F5"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="RowHeight" Value="36"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="CanUserResizeRows" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="SelectionMode" Value="Extended"/>
      <Setter Property="SelectionUnit" Value="FullRow"/>
      <Setter Property="RowBackground" Value="White"/>
      <Setter Property="AlternatingRowBackground" Value="#FAFBFD"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#F6F8FB"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="BorderBrush" Value="#E6EAF0"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#E3EEFC"/>
          <Setter Property="Foreground" Value="#1B2430"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Foreground" Value="{StaticResource Primary}"/>
      <Setter Property="Background" Value="#E6ECF5"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <!-- Status-Badge für Migrationsstatus -->
    <DataTemplate x:Key="StatusBadge">
      <Border x:Name="Badge" CornerRadius="10" Padding="10,3" HorizontalAlignment="Left" Background="#FFF4DB">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="BadgeDot" Width="7" Height="7" Fill="#C98400" Margin="0,0,7,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="BadgeText" Text="{Binding StatusText}" Foreground="#8A5A00" FontWeight="SemiBold" FontSize="12"/>
        </StackPanel>
      </Border>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Status}" Value="succeeded">
          <Setter TargetName="Badge" Property="Background" Value="#E3F5EB"/>
          <Setter TargetName="BadgeDot" Property="Fill" Value="#1E9E5A"/>
          <Setter TargetName="BadgeText" Property="Foreground" Value="#157347"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="failed">
          <Setter TargetName="Badge" Property="Background" Value="#FDE7E7"/>
          <Setter TargetName="BadgeDot" Property="Fill" Value="#D64545"/>
          <Setter TargetName="BadgeText" Property="Foreground" Value="#B42318"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="ready">
          <Setter TargetName="Badge" Property="Background" Value="#EEF1F5"/>
          <Setter TargetName="BadgeDot" Property="Fill" Value="#8592A3"/>
          <Setter TargetName="BadgeText" Property="Foreground" Value="#4A5565"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>

    <!-- Health-Anzeige -->
    <DataTemplate x:Key="HealthCell">
      <StackPanel Orientation="Horizontal">
        <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#A0AAB8" Margin="0,0,8,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="Txt" Text="{Binding Health}" Foreground="{StaticResource Muted}"/>
      </StackPanel>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Health}" Value="good">
          <Setter TargetName="Dot" Property="Fill" Value="#1E9E5A"/>
          <Setter TargetName="Txt" Property="Text" Value="Gut"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Health}" Value="suspicious">
          <Setter TargetName="Dot" Property="Fill" Value="#E0A100"/>
          <Setter TargetName="Txt" Property="Text" Value="Verdächtig"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Health}" Value="bad">
          <Setter TargetName="Dot" Property="Fill" Value="#D64545"/>
          <Setter TargetName="Txt" Property="Text" Value="Kritisch"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>

    <DataTemplate x:Key="TenantItem">
      <StackPanel>
        <TextBlock Text="{Binding Name, Mode=OneWay}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
        <TextBlock Foreground="{StaticResource Muted}" FontSize="11" Margin="0,2,0,0" TextTrimming="CharacterEllipsis">
          <Run Text="{Binding DataRegion, Mode=OneWay}"/><Run Text="  ·  "/><Run Text="{Binding Id, Mode=OneWay}"/>
        </TextBlock>
      </StackPanel>
    </DataTemplate>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="68"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="66"/>
    </Grid.RowDefinitions>

    <!-- ===== Kopfzeile ===== -->
    <Border Grid.Row="0" Background="{StaticResource Navy}" Padding="24,0">
      <DockPanel>
        <Border DockPanel.Dock="Left" Width="36" Height="36" CornerRadius="9" Background="{StaticResource Primary}" VerticalAlignment="Center">
          <Path Fill="White" Stretch="Uniform" Margin="9"
                Data="M12,1 L3,5 L3,11 C3,16.5 6.8,21.7 12,23 C17.2,21.7 21,16.5 21,11 L21,5 Z M10,17 L6,13 L7.4,11.6 L10,14.2 L16.6,7.6 L18,9 Z"/>
        </Border>
        <StackPanel DockPanel.Dock="Left" VerticalAlignment="Center" Margin="12,0,0,0">
          <TextBlock Text="Sophos Central · Geräte-Migration" Foreground="White" FontSize="17" FontWeight="SemiBold"/>
          <TextBlock x:Name="HeaderSub" Text="Server und Clients zwischen Tenants verschieben" Foreground="#9FB3CC" FontSize="12"/>
        </StackPanel>
        <TextBlock x:Name="HeaderContext" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#C9D6E6"
                   TextTrimming="CharacterEllipsis" Margin="20,0,0,0"/>
      </DockPanel>
    </Border>

    <!-- ===== Inhalt ===== -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="240"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Schritte -->
      <Border Grid.Column="0" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0" Padding="22,28,18,22">
        <DockPanel>
          <Border DockPanel.Dock="Bottom" Background="#F3F7FC" CornerRadius="8" Padding="12,10">
            <TextBlock TextWrapping="Wrap" FontSize="11.5" Foreground="#3E5573"
                       Text="Offline-Geräte werden migriert, sobald sie sich das nächste Mal bei Sophos Central melden. Richtlinien und Gruppen werden nicht übernommen."/>
          </Border>
          <StackPanel>
            <TextBlock Text="SCHRITTE" Style="{StaticResource Overline}" Margin="0,0,0,18"/>

            <Grid Margin="0,0,0,20">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Step1Circle" Width="30" Height="30" CornerRadius="15" Background="#E6ECF5">
                <TextBlock x:Name="Step1Num" Text="1" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="Step1Title" Text="Anmeldung" FontWeight="SemiBold"/>
                <TextBlock x:Name="Step1Sub" Text="API-Zugang" FontSize="11" Foreground="{StaticResource Muted}"/>
              </StackPanel>
            </Grid>
            <Grid Margin="0,0,0,20">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Step2Circle" Width="30" Height="30" CornerRadius="15" Background="#E6ECF5">
                <TextBlock x:Name="Step2Num" Text="2" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="Step2Title" Text="Tenants" FontWeight="SemiBold"/>
                <TextBlock x:Name="Step2Sub" Text="Quelle und Ziel" FontSize="11" Foreground="{StaticResource Muted}"/>
              </StackPanel>
            </Grid>
            <Grid Margin="0,0,0,20">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Step3Circle" Width="30" Height="30" CornerRadius="15" Background="#E6ECF5">
                <TextBlock x:Name="Step3Num" Text="3" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="Step3Title" Text="Geräte" FontWeight="SemiBold"/>
                <TextBlock x:Name="Step3Sub" Text="Server oder Clients" FontSize="11" Foreground="{StaticResource Muted}"/>
              </StackPanel>
            </Grid>
            <Grid Margin="0,0,0,20">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="Step4Circle" Width="30" Height="30" CornerRadius="15" Background="#E6ECF5">
                <TextBlock x:Name="Step4Num" Text="4" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="Step4Title" Text="Migration" FontWeight="SemiBold"/>
                <TextBlock x:Name="Step4Sub" Text="Start und Status" FontSize="11" Foreground="{StaticResource Muted}"/>
              </StackPanel>
            </Grid>
          </StackPanel>
        </DockPanel>
      </Border>

      <Grid Grid.Column="1" Margin="32,26,32,20">

        <!-- ===== Seite 1: Anmeldung ===== -->
        <ScrollViewer x:Name="Page1" VerticalScrollBarVisibility="Auto">
          <StackPanel MaxWidth="900" HorizontalAlignment="Left">
            <TextBlock Text="Anmeldung" Style="{StaticResource H1}"/>
            <TextBlock Text="Wie möchtest du dich bei Sophos Central anmelden?" Style="{StaticResource Sub}"/>

            <UniformGrid Columns="2" Margin="0,0,0,20">
              <RadioButton x:Name="RbTenantKeys" GroupName="Auth" Style="{StaticResource OptionCard}" IsChecked="True" Margin="0,0,8,0">
                <StackPanel>
                  <TextBlock Text="Tenant-API-Keys" FontWeight="SemiBold" FontSize="14"/>
                  <TextBlock Text="Je ein API-Key für Quell- und Ziel-Tenant. Standard-Variante, kein Partner-Zugang nötig."
                             TextWrapping="Wrap" Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="RbPartner" GroupName="Auth" Style="{StaticResource OptionCard}" Margin="8,0,0,0">
                <StackPanel>
                  <TextBlock Text="Partner-/Organisations-API-Key" FontWeight="SemiBold" FontSize="14"/>
                  <TextBlock Text="Ein Login für alle Tenants – Quell- und Ziel-Tenant werden anschließend aus einer Liste gewählt."
                             TextWrapping="Wrap" Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
                </StackPanel>
              </RadioButton>
            </UniformGrid>

            <Grid x:Name="PanelTenantKeys">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource Card}" Margin="0,0,8,0">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <Border Background="#E8F0FC" CornerRadius="4" Padding="7,2" VerticalAlignment="Center">
                      <TextBlock Text="QUELLE" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Primary}"/>
                    </Border>
                    <TextBlock Text="Quell-Tenant" FontSize="15" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBlock Text="Von hier werden die Geräte migriert." Foreground="{StaticResource Muted}" Margin="0,6,0,0"/>
                  <TextBlock Text="Client-ID" Style="{StaticResource FieldLabel}"/>
                  <TextBox x:Name="TxtSrcId"/>
                  <TextBlock Text="Client-Secret" Style="{StaticResource FieldLabel}"/>
                  <PasswordBox x:Name="PwdSrcSecret"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource Card}" Margin="8,0,0,0">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <Border Background="#E3F5EB" CornerRadius="4" Padding="7,2" VerticalAlignment="Center">
                      <TextBlock Text="ZIEL" FontSize="10.5" FontWeight="Bold" Foreground="#157347"/>
                    </Border>
                    <TextBlock Text="Ziel-Tenant" FontSize="15" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBlock Text="Hierhin werden die Geräte migriert." Foreground="{StaticResource Muted}" Margin="0,6,0,0"/>
                  <TextBlock Text="Client-ID" Style="{StaticResource FieldLabel}"/>
                  <TextBox x:Name="TxtDstId"/>
                  <TextBlock Text="Client-Secret" Style="{StaticResource FieldLabel}"/>
                  <PasswordBox x:Name="PwdDstSecret"/>
                </StackPanel>
              </Border>
            </Grid>

            <Border x:Name="PanelPartner" Style="{StaticResource Card}" Visibility="Collapsed" MaxWidth="460" HorizontalAlignment="Left">
              <StackPanel>
                <TextBlock Text="Partner-/Organisations-Zugang" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock Text="Nach der Anmeldung wählst du Quell- und Ziel-Tenant aus." Foreground="{StaticResource Muted}" Margin="0,6,0,0"/>
                <TextBlock Text="Client-ID" Style="{StaticResource FieldLabel}"/>
                <TextBox x:Name="TxtPartnerId"/>
                <TextBlock Text="Client-Secret" Style="{StaticResource FieldLabel}"/>
                <PasswordBox x:Name="PwdPartnerSecret"/>
              </StackPanel>
            </Border>

            <Border Background="#EEF4FD" CornerRadius="8" Padding="14,11" Margin="0,20,0,0">
              <TextBlock TextWrapping="Wrap" Foreground="#24456E" FontSize="12">
                <Run FontWeight="SemiBold" Text="Tipp: "/>
                <Run Text="Tenant-API-Keys erstellst du in Sophos Central Admin → Globale Einstellungen → API-Anmeldeinformationen (Rolle mindestens „API – Superadmin“). Partner-Keys findest du im Partner Dashboard → Einstellungen → API-Anmeldeinformationen."/>
              </TextBlock>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== Seite 2: Tenant-Auswahl ===== -->
        <Grid x:Name="Page2" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Text="Tenants auswählen" Style="{StaticResource H1}"/>
          <TextBlock Grid.Row="1" Text="Wähle den Tenant, aus dem die Geräte kommen, und den Tenant, in den sie migriert werden sollen. Beide müssen in derselben Datenregion liegen."
                     Style="{StaticResource Sub}"/>
          <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Style="{StaticResource Card}" Padding="16">
              <DockPanel>
                <StackPanel DockPanel.Dock="Top">
                  <StackPanel Orientation="Horizontal">
                    <Border Background="#E8F0FC" CornerRadius="4" Padding="7,2" VerticalAlignment="Center">
                      <TextBlock Text="QUELLE" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Primary}"/>
                    </Border>
                    <TextBlock Text="Quell-Tenant" FontSize="15" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBox x:Name="TxtSrcTenantSearch" Tag="Tenant suchen…" Margin="0,12,0,10"/>
                </StackPanel>
                <ListBox x:Name="LstSrcTenants" ItemTemplate="{StaticResource TenantItem}"/>
              </DockPanel>
            </Border>
            <Path Grid.Column="1" Data="M0,8 L22,8 M15,1 L22,8 L15,15" Stroke="{StaticResource Primary}" StrokeThickness="2.2"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="16,0"/>
            <Border Grid.Column="2" Style="{StaticResource Card}" Padding="16">
              <DockPanel>
                <StackPanel DockPanel.Dock="Top">
                  <StackPanel Orientation="Horizontal">
                    <Border Background="#E3F5EB" CornerRadius="4" Padding="7,2" VerticalAlignment="Center">
                      <TextBlock Text="ZIEL" FontSize="10.5" FontWeight="Bold" Foreground="#157347"/>
                    </Border>
                    <TextBlock Text="Ziel-Tenant" FontSize="15" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                  <TextBox x:Name="TxtDstTenantSearch" Tag="Tenant suchen…" Margin="0,12,0,10"/>
                </StackPanel>
                <ListBox x:Name="LstDstTenants" ItemTemplate="{StaticResource TenantItem}"/>
              </DockPanel>
            </Border>
          </Grid>
          <Border x:Name="TenantWarning" Grid.Row="3" Background="#FDECEC" CornerRadius="8" Padding="14,10" Margin="0,14,0,0" Visibility="Collapsed">
            <TextBlock x:Name="TenantWarningText" Foreground="#9B2C2C" TextWrapping="Wrap"/>
          </Border>
        </Grid>

        <!-- ===== Seite 3: Geräte ===== -->
        <Grid x:Name="Page3" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Text="Geräte auswählen" Style="{StaticResource H1}"/>
          <TextBlock Grid.Row="1" Text="Wähle den Gerätetyp und markiere die Geräte, die migriert werden sollen."
                     Style="{StaticResource Sub}"/>

          <DockPanel Grid.Row="2" Margin="0,0,0,12" LastChildFill="False">
            <Border DockPanel.Dock="Left" Background="#E9EEF5" CornerRadius="8" Padding="3">
              <StackPanel Orientation="Horizontal">
                <RadioButton x:Name="RbServer" GroupName="DevType" Style="{StaticResource Segment}" Content="Server"/>
                <RadioButton x:Name="RbClients" GroupName="DevType" Style="{StaticResource Segment}" Content="Clients"/>
              </StackPanel>
            </Border>
            <TextBox x:Name="TxtDeviceSearch" DockPanel.Dock="Left" Width="300" Margin="12,0,0,0"
                     Tag="Hostname, Betriebssystem oder Benutzer suchen…"/>
            <Button x:Name="BtnReload" DockPanel.Dock="Right" Style="{StaticResource BtnBase}" Content="↻  Neu laden" Margin="8,0,0,0"/>
            <Button x:Name="BtnSelectNone" DockPanel.Dock="Right" Style="{StaticResource BtnBase}" Content="Auswahl aufheben" Margin="8,0,0,0"/>
            <Button x:Name="BtnSelectAll" DockPanel.Dock="Right" Style="{StaticResource BtnBase}" Content="Alle markieren"/>
          </DockPanel>

          <Border Grid.Row="3" Style="{StaticResource Card}" Padding="0" ClipToBounds="True">
            <Grid>
              <DataGrid x:Name="GridDevices">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Width="46" CanUserSort="True" SortMemberPath="IsSelected">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <CheckBox IsChecked="{Binding IsSelected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                  HorizontalAlignment="Center" VerticalAlignment="Center" Cursor="Hand"/>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTextColumn Header="Hostname" Binding="{Binding Hostname}" Width="1.3*" MinWidth="150" FontWeight="SemiBold"/>
                  <DataGridTextColumn Header="Betriebssystem" Binding="{Binding OS}" Width="1.3*" MinWidth="140"/>
                  <DataGridTextColumn Header="Letzter Benutzer" Binding="{Binding LastUser}" Width="*" MinWidth="120"/>
                  <DataGridTemplateColumn Header="Health" Width="120" CellTemplate="{StaticResource HealthCell}" SortMemberPath="Health"/>
                  <DataGridTextColumn Header="Zuletzt online" Binding="{Binding LastSeen, StringFormat='dd.MM.yyyy HH:mm'}" Width="140"/>
                </DataGrid.Columns>
              </DataGrid>
              <StackPanel x:Name="DevicesEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False">
                <Path Data="M3,4 L21,4 L21,16 L3,16 Z M8,20 L16,20 M12,16 L12,20" Stroke="#B4BFCD" StrokeThickness="1.6"
                      Width="44" Height="40" Stretch="Uniform" HorizontalAlignment="Center"/>
                <TextBlock x:Name="DevicesEmptyText" Text="Bitte oben wählen: Server oder Clients" Foreground="{StaticResource Muted}"
                           FontSize="14" Margin="0,12,0,0" HorizontalAlignment="Center"/>
              </StackPanel>
            </Grid>
          </Border>

          <DockPanel Grid.Row="4" Margin="2,10,2,0">
            <TextBlock x:Name="TxtSelectionInfo" DockPanel.Dock="Left" FontWeight="SemiBold" Text="0 von 0 Geräten ausgewählt"/>
            <TextBlock HorizontalAlignment="Right" Foreground="{StaticResource Muted}" FontSize="12"
                       Text="Tipp: Mehrere Zeilen mit Strg/Shift markieren und Leertaste drücken, um sie an- oder abzuwählen."/>
          </DockPanel>
        </Grid>

        <!-- ===== Seite 4: Migration ===== -->
        <Grid x:Name="Page4" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock Text="Migration" Style="{StaticResource H1}"/>
          <TextBlock x:Name="TxtMigrateSub" Grid.Row="1" Style="{StaticResource Sub}"
                     Text="Prüfe die Zusammenfassung und starte die Migration."/>

          <!-- Zusammenfassung -->
          <Border Grid.Row="2" Style="{StaticResource Card}" Padding="20,16">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="QUELLE" Style="{StaticResource Overline}"/>
                <TextBlock x:Name="TxtSumSrc" FontSize="16" FontWeight="SemiBold" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="TxtSumSrcId" FontSize="11" Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <Path Grid.Column="1" Data="M0,8 L26,8 M19,1 L26,8 L19,15" Stroke="{StaticResource Primary}" StrokeThickness="2.2"
                    StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="20,0"/>
              <StackPanel Grid.Column="2">
                <TextBlock Text="ZIEL" Style="{StaticResource Overline}"/>
                <TextBlock x:Name="TxtSumDst" FontSize="16" FontWeight="SemiBold" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="TxtSumDstId" FontSize="11" Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <Border Grid.Column="3" Width="1" Background="{StaticResource Line}" Margin="24,0"/>
              <StackPanel Grid.Column="4" MinWidth="110">
                <TextBlock Text="GERÄTE" Style="{StaticResource Overline}"/>
                <TextBlock x:Name="TxtSumCount" FontSize="26" FontWeight="SemiBold" Foreground="{StaticResource Primary}"/>
                <TextBlock x:Name="TxtSumType" FontSize="11" Foreground="{StaticResource Muted}"/>
              </StackPanel>
            </Grid>
          </Border>

          <!-- Hinweis vor dem Start / Fortschritt nach dem Start -->
          <Border x:Name="PanelPreStart" Grid.Row="3" Background="#FFF8E6" BorderBrush="#F2D589" BorderThickness="1"
                  CornerRadius="8" Padding="14,11" Margin="0,14,0,0">
            <TextBlock TextWrapping="Wrap" Foreground="#6B4A00">
              <Run FontWeight="SemiBold" Text="Bitte beachten: "/>
              <Run Text="Die Geräte werden aus dem Quell-Tenant entfernt und im Ziel-Tenant mit Standardkonfiguration angelegt – Richtlinien und Gruppen werden nicht übernommen. Offline-Geräte werden migriert, sobald sie sich das nächste Mal melden."/>
            </TextBlock>
          </Border>

          <StackPanel x:Name="PanelProgress" Grid.Row="3" Margin="0,14,0,0" Visibility="Collapsed">
            <UniformGrid Columns="4">
              <Border Style="{StaticResource Card}" Padding="16,12" Margin="0,0,8,0">
                <StackPanel>
                  <TextBlock Text="ERFOLGREICH" Style="{StaticResource Overline}"/>
                  <TextBlock x:Name="KpiOk" Text="0" FontSize="26" FontWeight="SemiBold" Foreground="{StaticResource Success}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Padding="16,12" Margin="4,0,4,0">
                <StackPanel>
                  <TextBlock Text="FEHLGESCHLAGEN" Style="{StaticResource Overline}"/>
                  <TextBlock x:Name="KpiFailed" Text="0" FontSize="26" FontWeight="SemiBold" Foreground="{StaticResource Danger}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Padding="16,12" Margin="8,0,4,0">
                <StackPanel>
                  <TextBlock Text="AUSSTEHEND" Style="{StaticResource Overline}"/>
                  <TextBlock x:Name="KpiOpen" Text="0" FontSize="26" FontWeight="SemiBold" Foreground="{StaticResource Warning}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Padding="16,12" Margin="8,0,0,0">
                <StackPanel>
                  <TextBlock Text="FORTSCHRITT" Style="{StaticResource Overline}"/>
                  <TextBlock x:Name="TxtProgress" Text="0 von 0 abgeschlossen" FontWeight="SemiBold" Margin="0,8,0,8"/>
                  <ProgressBar x:Name="PrgMigration" Minimum="0" Maximum="1" Value="0"/>
                </StackPanel>
              </Border>
            </UniformGrid>
            <DockPanel Margin="0,12,0,0">
              <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="Job-ID" Style="{StaticResource Overline}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBox x:Name="TxtJobId" IsReadOnly="True" Width="300" FontFamily="Consolas" Padding="8,5"/>
                <TextBlock x:Name="TxtPollInfo" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="14,0,0,0"/>
              </StackPanel>
              <StackPanel HorizontalAlignment="Right" Orientation="Horizontal">
                <Button x:Name="BtnRefreshStatus" Style="{StaticResource BtnBase}" Content="↻  Status jetzt abfragen"/>
                <Button x:Name="BtnStopPolling" Style="{StaticResource BtnBase}" Content="Abfrage beenden" Margin="8,0,0,0"/>
                <Button x:Name="BtnExport" Style="{StaticResource BtnBase}" Content="CSV exportieren" Margin="8,0,0,0"/>
              </StackPanel>
            </DockPanel>
          </StackPanel>

          <!-- Geräteliste und Protokoll -->
          <Grid Grid.Row="4" Margin="0,14,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition x:Name="LogColumn" Width="0"/>
            </Grid.ColumnDefinitions>
            <Border Style="{StaticResource Card}" Padding="0" ClipToBounds="True">
              <DataGrid x:Name="GridMigrate">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Hostname" Binding="{Binding Hostname}" Width="*" MinWidth="150" FontWeight="SemiBold"/>
                  <DataGridTextColumn Header="Betriebssystem" Binding="{Binding OS}" Width="*" MinWidth="130"/>
                  <DataGridTemplateColumn Header="Status" Width="250" CellTemplate="{StaticResource StatusBadge}" SortMemberPath="StatusText"/>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
            <Border x:Name="LogCard" Grid.Column="1" Style="{StaticResource Card}" Padding="14" Margin="14,0,0,0" Visibility="Collapsed">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Text="PROTOKOLL" Style="{StaticResource Overline}" Margin="0,0,0,8"/>
                <TextBox x:Name="TxtLog" IsReadOnly="True" TextWrapping="Wrap" FontFamily="Consolas" FontSize="11.5"
                         VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top" BorderThickness="0" Padding="0" Background="#FAFBFD"/>
              </DockPanel>
            </Border>
          </Grid>
        </Grid>
      </Grid>
    </Grid>

    <!-- ===== Fußzeile ===== -->
    <Border Grid.Row="2" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="24,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnBack" Style="{StaticResource BtnBase}" Content="←  Zurück" Margin="0,0,10,0" MinWidth="110"/>
          <Button x:Name="BtnNext" Style="{StaticResource BtnPrimary}" Content="Weiter  →" MinWidth="170"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#A0AAB8" Margin="0,0,10,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="TxtStatus" Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"
                     Text="Bereit."/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ===== Warte-Overlay ===== -->
    <Grid x:Name="Overlay" Grid.RowSpan="3" Background="#A6F3F5F9" Visibility="Collapsed">
      <Border Style="{StaticResource Card}" HorizontalAlignment="Center" VerticalAlignment="Center" Width="380" Padding="24,20">
        <StackPanel>
          <TextBlock x:Name="OverlayText" Text="Bitte warten…" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap"/>
          <TextBlock Text="Kommunikation mit Sophos Central läuft." Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
          <ProgressBar IsIndeterminate="True" Height="4" Margin="0,16,0,0"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

try {
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
} catch {
    # Ohne sichtbare Konsole (Start-GUI.cmd) wäre der Fehler sonst unsichtbar
    [void][System.Windows.MessageBox]::Show("Die Oberfläche konnte nicht geladen werden:`n$($_.Exception.Message)", 'Sophos Geräte-Migration', 'OK', 'Error')
    exit 1
}
$ui = @{}
foreach ($node in $xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $ui[$name] = $window.FindName($name) }
}

# ============================================================================
#  Zustand und Datenquellen
# ============================================================================

$script:State = @{
    Page        = 1
    Mode        = 'tenant'     # tenant | partner
    Src         = $null        # Tenant-Kontext: Session, TenantId, ApiHost, Region, Name
    Dst         = $null
    Partner     = $null        # Session + IdType bei Partner-Login
    DeviceType  = $null        # server | computer
    LoadedKey   = $null
    Bulk        = $false
    Started     = $false
    JobId       = $null
    Polling     = $false
    PollBusy    = $false
    NextPoll    = $null
    LastPoll    = $null
    Deadline    = $null
}
$script:PollIntervalSec = 30
$script:MaxWaitMinutes  = 30

$script:Devices        = New-Object 'System.Collections.ObjectModel.ObservableCollection[SophosDeviceItem]'
$script:MigrationItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[SophosDeviceItem]'
$script:SrcTenants     = New-Object 'System.Collections.ObjectModel.ObservableCollection[SophosTenantItem]'
$script:DstTenants     = New-Object 'System.Collections.ObjectModel.ObservableCollection[SophosTenantItem]'

$ui.GridDevices.ItemsSource   = $script:Devices
$ui.GridMigrate.ItemsSource   = $script:MigrationItems
$ui.LstSrcTenants.ItemsSource = $script:SrcTenants
$ui.LstDstTenants.ItemsSource = $script:DstTenants

function Test-Contains {
    param([string]$Value, [string]$Search)
    return ($Value -and $Value.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

$script:DeviceView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Devices)
$script:DeviceView.Filter = {
    param($d)
    $t = $ui.TxtDeviceSearch.Text.Trim()
    if (-not $t) { return $true }
    return ((Test-Contains $d.Hostname $t) -or (Test-Contains $d.OS $t) -or (Test-Contains $d.LastUser $t))
}
$script:SrcTenantView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:SrcTenants)
$script:SrcTenantView.Filter = {
    param($t)
    $s = $ui.TxtSrcTenantSearch.Text.Trim()
    if (-not $s) { return $true }
    return ((Test-Contains $t.Name $s) -or (Test-Contains $t.Id $s))
}
$script:DstTenantView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:DstTenants)
$script:DstTenantView.Filter = {
    param($t)
    $s = $ui.TxtDstTenantSearch.Text.Trim()
    if (-not $s) { return $true }
    return ((Test-Contains $t.Name $s) -or (Test-Contains $t.Id $s))
}

# ============================================================================
#  UI-Hilfsfunktionen
# ============================================================================

function New-Brush { param([string]$Hex) return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }

function Show-Busy { param([string]$Text) $ui.OverlayText.Text = $Text; $ui.Overlay.Visibility = 'Visible' }
function Hide-Busy { $ui.Overlay.Visibility = 'Collapsed' }
function Test-Busy { return ($ui.Overlay.Visibility -eq 'Visible') }

function Set-Status {
    param([string]$Text, [ValidateSet('info', 'ok', 'warn', 'error')][string]$Kind = 'info')
    $color = switch ($Kind) { 'ok' { '#1E9E5A' } 'warn' { '#E0A100' } 'error' { '#D64545' } default { '#A0AAB8' } }
    $ui.StatusDot.Fill = New-Brush $color
    $ui.TxtStatus.Text = $Text
}

function Show-Error {
    param([string]$Text)
    Set-Status ($Text -split "`n")[0] 'error'
    [void][System.Windows.MessageBox]::Show($window, $Text, 'Sophos Geräte-Migration', 'OK', 'Error')
}

function Show-Warning {
    param([string]$Text)
    Set-Status $Text 'warn'
    [void][System.Windows.MessageBox]::Show($window, $Text, 'Sophos Geräte-Migration', 'OK', 'Warning')
}

function Write-Log {
    param([string]$Text)
    $ui.TxtLog.AppendText(("[{0:HH:mm:ss}] {1}`r`n" -f (Get-Date), $Text))
    $ui.TxtLog.ScrollToEnd()
}

function Get-DeviceLabel { if ($script:State.DeviceType -eq 'server') { 'Server' } else { 'Clients' } }

function ConvertTo-StatusText {
    param([string]$Status)
    switch ($Status) {
        'succeeded' { 'Erfolgreich migriert' }
        'failed'    { 'Fehlgeschlagen' }
        'pending'   { 'Ausstehend – wartet auf Check-in' }
        'ready'     { 'Bereit' }
        'started'   { 'Gestartet' }
        default     { if ($Status) { $Status } else { 'Unbekannt' } }
    }
}

function Update-Steps {
    $page = $script:State.Page
    $doneBrush   = New-Brush '#1E9E5A'
    $activeBrush = New-Brush '#0067D8'
    $idleBrush   = New-Brush '#E6ECF5'
    $mutedBrush  = New-Brush '#5F6B7A'
    $textBrush   = New-Brush '#1B2430'
    $white       = [System.Windows.Media.Brushes]::White

    foreach ($i in 1..4) {
        $circle = $ui["Step${i}Circle"]; $num = $ui["Step${i}Num"]; $title = $ui["Step${i}Title"]
        $done = ($i -lt $page) -or ($i -eq 4 -and $script:State.Started -and -not $script:State.Polling)
        if ($done) {
            $circle.Background = $doneBrush; $num.Text = '✓'; $num.Foreground = $white; $title.Foreground = $textBrush
        } elseif ($i -eq $page) {
            $circle.Background = $activeBrush; $num.Text = "$i"; $num.Foreground = $white; $title.Foreground = $textBrush
        } else {
            $circle.Background = $idleBrush; $num.Text = "$i"; $num.Foreground = $mutedBrush; $title.Foreground = $mutedBrush
        }
    }
    $ui.Step2Sub.Text = if ($script:State.Mode -eq 'tenant' -and $page -gt 1) { 'automatisch (Tenant-Keys)' } else { 'Quelle und Ziel' }
    $ui.Step3Sub.Text = if ($script:State.DeviceType) { Get-DeviceLabel } else { 'Server oder Clients' }
    $ui.Step4Sub.Text = if ($script:State.Polling) { 'läuft…' } elseif ($script:State.Started) { 'abgeschlossen' } else { 'Start und Status' }
}

function Update-Footer {
    $s = $script:State
    $ui.BtnBack.Visibility = 'Visible'
    $ui.BtnNext.IsEnabled  = $true
    switch ($s.Page) {
        1 { $ui.BtnBack.Visibility = 'Collapsed'; $ui.BtnNext.Content = 'Anmelden  →' }
        2 { $ui.BtnNext.Content = 'Weiter  →'; $ui.BtnNext.IsEnabled = Test-TenantSelection }
        3 { $ui.BtnNext.Content = 'Weiter  →'; $ui.BtnNext.IsEnabled = ((Get-SelectedDevices).Count -gt 0) }
        4 {
            if ($s.Started) { $ui.BtnBack.Visibility = 'Collapsed'; $ui.BtnNext.Content = 'Schließen' }
            else            { $ui.BtnNext.Content = 'Migration starten' }
        }
    }
}

function Show-Page {
    param([int]$Page)
    $script:State.Page = $Page
    foreach ($i in 1..4) { $ui["Page$i"].Visibility = if ($i -eq $Page) { 'Visible' } else { 'Collapsed' } }
    Update-Steps
    Update-Footer
}

function Update-HeaderContext {
    $s = $script:State
    $ui.HeaderContext.Text = if ($s.Src -and $s.Dst) { "$($s.Src.Name)   →   $($s.Dst.Name)" } else { '' }
}

# ============================================================================
#  Schritt 1: Anmeldung
# ============================================================================

function Update-AuthPanels {
    $tenantMode = [bool]$ui.RbTenantKeys.IsChecked
    $ui.PanelTenantKeys.Visibility = if ($tenantMode) { 'Visible' } else { 'Collapsed' }
    $ui.PanelPartner.Visibility    = if ($tenantMode) { 'Collapsed' } else { 'Visible' }
}

function Invoke-Login {
    if ($ui.RbTenantKeys.IsChecked) {
        $args1 = @{
            SrcId = $ui.TxtSrcId.Text.Trim(); SrcSecret = $ui.PwdSrcSecret.Password
            DstId = $ui.TxtDstId.Text.Trim(); DstSecret = $ui.PwdDstSecret.Password
        }
        if (-not $args1.SrcId -or -not $args1.SrcSecret -or -not $args1.DstId -or -not $args1.DstSecret) {
            Show-Warning 'Bitte Client-ID und Client-Secret für Quell- und Ziel-Tenant eingeben.'
            return
        }

        Start-BgTask -BusyText 'Anmeldung an Quell- und Ziel-Tenant…' -Arguments $args1 -Work {
            param($SrcId, $SrcSecret, $DstId, $DstSecret)
            $result = @{}
            foreach ($side in @(
                    @{ Key = 'Src'; Id = $SrcId; Secret = $SrcSecret; Label = 'Quell-Tenant' },
                    @{ Key = 'Dst'; Id = $DstId; Secret = $DstSecret; Label = 'Ziel-Tenant' })) {
                try {
                    $session = New-SophosSession -Id $side.Id -Secret $side.Secret
                    $who = Get-SophosWhoAmI -Session $session
                } catch {
                    throw "Anmeldung am $($side.Label) fehlgeschlagen: $($_.Exception.Message)"
                }
                if ($who.idType -ne 'tenant') {
                    throw "Der API-Key für den $($side.Label) ist kein Tenant-Key (Typ: $($who.idType)). Für Partner-/Organisations-Keys bitte die zweite Anmeldeart wählen."
                }
                $result[$side.Key] = [pscustomobject]@{
                    Session  = $session
                    TenantId = $who.id
                    ApiHost  = $who.apiHosts.dataRegion
                    Region   = Get-RegionFromApiHost $who.apiHosts.dataRegion
                    Name     = $side.Label
                }
            }
            [pscustomobject]$result
        } -OnSuccess {
            param($r)
            if ($r.Src.TenantId -eq $r.Dst.TenantId) {
                Show-Error 'Quell- und Ziel-Tenant sind identisch – bitte die API-Keys zweier unterschiedlicher Tenants verwenden.'
                return
            }
            if ($r.Src.ApiHost -ne $r.Dst.ApiHost) {
                Show-Error "Quell- und Ziel-Tenant liegen in unterschiedlichen Datenregionen ($($r.Src.Region) / $($r.Dst.Region)).`nDie Sophos-Migration-API unterstützt nur Migrationen innerhalb derselben Region."
                return
            }
            $script:State.Mode = 'tenant'
            $script:State.Src  = $r.Src
            $script:State.Dst  = $r.Dst
            $script:State.LoadedKey = $null
            Update-HeaderContext
            Set-Status "Angemeldet – Quelle [$($r.Src.TenantId)], Ziel [$($r.Dst.TenantId)], Region $($r.Src.Region)." 'ok'
            Show-DevicesPage
        } -OnError {
            param($e)
            Show-Error $e
        }
    } else {
        $args1 = @{ Id = $ui.TxtPartnerId.Text.Trim(); Secret = $ui.PwdPartnerSecret.Password }
        if (-not $args1.Id -or -not $args1.Secret) {
            Show-Warning 'Bitte Client-ID und Client-Secret des Partner-/Organisations-Keys eingeben.'
            return
        }

        Start-BgTask -BusyText 'Anmeldung und Laden der Tenant-Liste…' -Arguments $args1 -Work {
            param($Id, $Secret)
            try {
                $session = New-SophosSession -Id $Id -Secret $Secret
                $who = Get-SophosWhoAmI -Session $session
            } catch {
                throw "Anmeldung fehlgeschlagen: $($_.Exception.Message)"
            }
            if ($who.idType -notin @('partner', 'organization')) {
                throw "Der API-Key ist kein Partner-/Organisations-Key (Typ: $($who.idType)). Für Tenant-API-Keys bitte die erste Anmeldeart wählen."
            }
            $tenants = Get-SophosTenants -Session $session -IdType $who.idType -EntityId $who.id |
                Where-Object { $_.apiHost } | Sort-Object name
            [pscustomobject]@{ Session = $session; IdType = $who.idType; Tenants = @($tenants) }
        } -OnSuccess {
            param($r)
            if (-not $r.Tenants -or $r.Tenants.Count -eq 0) { Show-Error 'Es wurden keine Tenants gefunden.'; return }

            $script:State.Mode    = 'partner'
            $script:State.Partner = $r
            $script:SrcTenants.Clear(); $script:DstTenants.Clear()
            foreach ($t in $r.Tenants) {
                foreach ($list in $script:SrcTenants, $script:DstTenants) {
                    $item = New-Object SophosTenantItem
                    $item.Name = $t.name; $item.Id = $t.id; $item.DataRegion = $t.dataRegion; $item.ApiHost = $t.apiHost
                    $list.Add($item)
                }
            }
            Set-Status "Angemeldet ($($r.IdType)) – $($r.Tenants.Count) Tenants gefunden." 'ok'
            Show-Page 2
            Update-TenantWarning
        } -OnError {
            param($e)
            Show-Error $e
        }
    }
}

# ============================================================================
#  Schritt 2: Tenant-Auswahl (Partner-Login)
# ============================================================================

function Get-TenantProblem {
    $src = $ui.LstSrcTenants.SelectedItem
    $dst = $ui.LstDstTenants.SelectedItem
    if (-not $src -or -not $dst) { return $null }
    if ($src.Id -eq $dst.Id) { return 'Quell- und Ziel-Tenant sind identisch – bitte zwei unterschiedliche Tenants wählen.' }
    if (($src.DataRegion -and $dst.DataRegion -and $src.DataRegion -ne $dst.DataRegion) -or $src.ApiHost -ne $dst.ApiHost) {
        return "Die Tenants liegen in unterschiedlichen Datenregionen ($($src.DataRegion) / $($dst.DataRegion)). Die Sophos-Migration-API unterstützt nur Migrationen innerhalb derselben Region."
    }
    return $null
}

function Test-TenantSelection {
    return ($ui.LstSrcTenants.SelectedItem -and $ui.LstDstTenants.SelectedItem -and -not (Get-TenantProblem))
}

function Update-TenantWarning {
    $problem = Get-TenantProblem
    $ui.TenantWarning.Visibility = if ($problem) { 'Visible' } else { 'Collapsed' }
    $ui.TenantWarningText.Text = "$problem"
    if ($script:State.Page -eq 2) { Update-Footer }
}

function Confirm-Tenants {
    if (-not (Test-TenantSelection)) { return }
    $src = $ui.LstSrcTenants.SelectedItem
    $dst = $ui.LstDstTenants.SelectedItem
    $session = $script:State.Partner.Session

    $newSrc = [pscustomobject]@{ Session = $session; TenantId = $src.Id; ApiHost = $src.ApiHost; Region = $src.DataRegion; Name = $src.Name }
    $newDst = [pscustomobject]@{ Session = $session; TenantId = $dst.Id; ApiHost = $dst.ApiHost; Region = $dst.DataRegion; Name = $dst.Name }
    if (-not $script:State.Src -or $script:State.Src.TenantId -ne $newSrc.TenantId) { $script:State.LoadedKey = $null }
    $script:State.Src = $newSrc
    $script:State.Dst = $newDst
    Update-HeaderContext
    Show-DevicesPage
}

# ============================================================================
#  Schritt 3: Geräte
# ============================================================================

function Get-SelectedDevices {
    $list = New-Object System.Collections.Generic.List[SophosDeviceItem]
    foreach ($d in $script:Devices) { if ($d.IsSelected) { $list.Add($d) } }
    return , $list
}

function Update-SelectionInfo {
    if ($script:State.Bulk) { return }
    $total = $script:Devices.Count
    $sel = (Get-SelectedDevices).Count
    $ui.TxtSelectionInfo.Text = "$sel von $total $(if ($script:State.DeviceType) { Get-DeviceLabel } else { 'Geräten' }) ausgewählt"

    $visible = 0
    foreach ($d in $script:DeviceView) { $visible++; break }
    if ($visible -gt 0) {
        $ui.DevicesEmpty.Visibility = 'Collapsed'
    } else {
        $ui.DevicesEmpty.Visibility = 'Visible'
        $ui.DevicesEmptyText.Text =
            if (-not $script:State.DeviceType) { 'Bitte oben wählen: Server oder Clients' }
            elseif ($total -eq 0)              { "Im Quell-Tenant wurden keine $(Get-DeviceLabel) gefunden." }
            else                               { 'Keine Treffer für die Suche.' }
    }
    if ($script:State.Page -eq 3) { Update-Footer }
}

$script:OnDeviceChanged = {
    param($sender, $e)
    if ($e.PropertyName -eq 'IsSelected') { Update-SelectionInfo }
}

function Set-DeviceSelection {
    param([System.Collections.IEnumerable]$Items, [bool]$Value)
    $script:State.Bulk = $true
    try { foreach ($d in @($Items)) { $d.IsSelected = $Value } }
    finally { $script:State.Bulk = $false }
    Update-SelectionInfo
}

function Show-DevicesPage {
    Show-Page 3
    $key = if ($script:State.DeviceType) { "$($script:State.Src.TenantId)|$($script:State.DeviceType)" }
    if ($script:State.DeviceType -and $script:State.LoadedKey -ne $key) { Update-DeviceList }
    else { Update-SelectionInfo }
}

function Update-DeviceList {
    if (-not $script:State.DeviceType) { return }
    $script:Devices.Clear()
    Update-SelectionInfo
    Update-Steps

    $label = Get-DeviceLabel
    Start-BgTask -BusyText "Lade $label aus '$($script:State.Src.Name)'…" `
        -Arguments @{ Tenant = $script:State.Src; Type = $script:State.DeviceType } -Work {
        param($Tenant, $Type)
        [pscustomobject]@{ Key = "$($Tenant.TenantId)|$Type"; Items = @(Get-SophosEndpoints -Tenant $Tenant -Type $Type) }
    } -OnSuccess {
        param($r)
        foreach ($e in $r.Items) {
            $item = New-Object SophosDeviceItem
            $item.Id       = $e.id
            $item.Hostname = $e.hostname
            $item.OS       = $e.os.name
            $item.LastUser = $e.associatedPerson.viaLogin
            $item.Health   = $e.health.overall
            if ($e.lastSeenAt) {
                try {
                    $seen = if ($e.lastSeenAt -is [datetime]) { $e.lastSeenAt }
                            else { [datetime]::Parse($e.lastSeenAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
                    $item.LastSeen = $seen.ToLocalTime()
                } catch { }
            }
            $item.add_PropertyChanged($script:OnDeviceChanged)
            $script:Devices.Add($item)
        }
        $script:State.LoadedKey = $r.Key
        Update-SelectionInfo
        Set-Status "$($script:Devices.Count) $(Get-DeviceLabel) im Quell-Tenant gefunden." 'ok'
    } -OnError {
        param($e)
        Show-Error "Geräte konnten nicht geladen werden:`n$e"
    }
}

# ============================================================================
#  Schritt 4: Migration
# ============================================================================

function Show-MigrationPage {
    $selected = Get-SelectedDevices
    if ($selected.Count -eq 0) { return }

    $script:MigrationItems.Clear()
    foreach ($d in ($selected | Sort-Object Hostname)) {
        $d.Status = 'ready'; $d.StatusText = ConvertTo-StatusText 'ready'
        $script:MigrationItems.Add($d)
    }
    $s = $script:State
    $ui.TxtSumSrc.Text   = $s.Src.Name
    $ui.TxtSumSrcId.Text = $s.Src.TenantId
    $ui.TxtSumDst.Text   = $s.Dst.Name
    $ui.TxtSumDstId.Text = $s.Dst.TenantId
    $ui.TxtSumCount.Text = "$($selected.Count)"
    $ui.TxtSumType.Text  = "$(Get-DeviceLabel) · Region $($s.Src.Region)"
    $ui.TxtMigrateSub.Text = 'Prüfe die Zusammenfassung und starte die Migration.'
    Show-Page 4
}

function Start-Migration {
    $s = $script:State
    $count = $script:MigrationItems.Count
    $answer = [System.Windows.MessageBox]::Show($window,
        "Sollen $count $(Get-DeviceLabel) von '$($s.Src.Name)' nach '$($s.Dst.Name)' migriert werden?`n`nRichtlinien und Gruppen werden nicht übernommen.",
        'Migration starten', 'YesNo', 'Warning')
    if ("$answer" -ne 'Yes') { return }

    [string[]]$ids = @($script:MigrationItems | ForEach-Object { $_.Id })

    Start-BgTask -BusyText 'Migration wird gestartet…' -Arguments @{ Src = $s.Src; Dst = $s.Dst; Ids = $ids } -Work {
        param($Src, $Dst, [string[]]$Ids)

        # Schritt 1: Migrations-Job im ZIEL-Tenant anlegen (liefert Job-ID + Token)
        $createBody = @{ fromTenant = $Src.TenantId; endpoints = $Ids } | ConvertTo-Json -Depth 4
        try {
            $job = Invoke-SophosApi -Method Post -Uri "$($Dst.ApiHost)/endpoint/v1/migrations" `
                -Headers (Get-SophosTenantHeaders -Tenant $Dst) -ContentType 'application/json' -Body $createBody
        } catch {
            throw "Fehler beim Anlegen des Migrations-Jobs im Ziel-Tenant:`n$($_.Exception.Message)"
        }

        # Schritt 2: Migration im QUELL-Tenant bestätigen/starten
        $startBody = @{ token = $job.token; endpoints = $Ids } | ConvertTo-Json -Depth 4
        try {
            $null = Invoke-SophosApi -Method Put -Uri "$($Src.ApiHost)/endpoint/v1/migrations/$($job.id)" `
                -Headers (Get-SophosTenantHeaders -Tenant $Src) -ContentType 'application/json' -Body $startBody
        } catch {
            throw "Fehler beim Starten der Migration im Quell-Tenant (Job $($job.id)):`n$($_.Exception.Message)"
        }
        [pscustomobject]@{ JobId = $job.id }
    } -OnSuccess {
        param($r)
        $st = $script:State
        $st.Started  = $true
        $st.JobId    = $r.JobId
        $st.Polling  = $true
        $st.Deadline = (Get-Date).AddMinutes($script:MaxWaitMinutes)
        $st.NextPoll = (Get-Date).AddSeconds(5)

        foreach ($d in $script:MigrationItems) { $d.Status = 'started'; $d.StatusText = ConvertTo-StatusText 'started' }

        $ui.PanelPreStart.Visibility = 'Collapsed'
        $ui.PanelProgress.Visibility = 'Visible'
        $ui.LogColumn.Width = New-Object System.Windows.GridLength 360
        $ui.LogCard.Visibility = 'Visible'
        $ui.TxtJobId.Text = $r.JobId
        $ui.TxtMigrateSub.Text = "Die Migration läuft. Der Status wird alle $($script:PollIntervalSec) Sekunden abgefragt (max. $($script:MaxWaitMinutes) Minuten)."

        Write-Log "Migrations-Job im Ziel-Tenant erstellt (ID: $($r.JobId))."
        Write-Log "Migration im Quell-Tenant gestartet – $($script:MigrationItems.Count) Gerät(e)."
        Write-Log 'Die Geräte holen den Auftrag bei ihrem nächsten Check-in ab.'
        Update-Kpis
        Update-Steps
        Update-Footer
        Set-Status "Migration gestartet (Job $($r.JobId))." 'ok'
    } -OnError {
        param($e)
        Show-Error $e
    }
}

function Update-Kpis {
    $ok = 0; $failed = 0
    foreach ($d in $script:MigrationItems) {
        if ($d.Status -eq 'succeeded') { $ok++ } elseif ($d.Status -eq 'failed') { $failed++ }
    }
    $total = $script:MigrationItems.Count
    $ui.KpiOk.Text     = "$ok"
    $ui.KpiFailed.Text = "$failed"
    $ui.KpiOpen.Text   = "$($total - $ok - $failed)"
    $ui.PrgMigration.Maximum = [Math]::Max(1, $total)
    $ui.PrgMigration.Value   = $ok + $failed
    $ui.TxtProgress.Text = "$($ok + $failed) von $total abgeschlossen"
    return [pscustomobject]@{ Ok = $ok; Failed = $failed; Open = $total - $ok - $failed }
}

function Stop-Polling {
    param([string]$Reason)
    $script:State.Polling = $false
    if ($Reason) { Write-Log $Reason }
    $ui.BtnStopPolling.IsEnabled = $false
    Update-Steps
    Update-PollInfo
}

function Invoke-StatusPoll {
    $s = $script:State
    if ($s.PollBusy -or -not $s.JobId) { return }
    $s.PollBusy = $true
    $ui.BtnRefreshStatus.IsEnabled = $false
    Update-PollInfo

    Start-BgTask -Arguments @{ Tenant = $s.Src; JobId = $s.JobId } -Work {
        param($Tenant, $JobId)
        [pscustomobject]@{ Items = @(Get-SophosMigrationStatus -Tenant $Tenant -JobId $JobId) }
    } -OnSuccess {
        param($r)
        $st = $script:State
        $st.PollBusy = $false
        $st.LastPoll = Get-Date
        $ui.BtnRefreshStatus.IsEnabled = $true

        $byId = @{}
        foreach ($d in $script:MigrationItems) { $byId[$d.Id] = $d }
        foreach ($it in $r.Items) {
            $dev = $byId["$($it.id)"]
            if (-not $dev) { continue }
            $status = "$($it.status)"
            if ($dev.Status -ne $status) {
                $dev.Status = $status
                $dev.StatusText = ConvertTo-StatusText $status
                switch ($status) {
                    'succeeded' { Write-Log "[OK]      $($dev.Hostname) → erfolgreich migriert" }
                    'failed'    { Write-Log "[FEHLER]  $($dev.Hostname) → Migration fehlgeschlagen" }
                    default     { Write-Log "[STATUS]  $($dev.Hostname) → $($dev.StatusText)" }
                }
            }
        }
        $k = Update-Kpis

        if ($st.Polling) {
            if ($r.Items.Count -gt 0 -and $k.Open -eq 0) {
                Stop-Polling "Alle Geräte abgeschlossen: $($k.Ok) erfolgreich, $($k.Failed) fehlgeschlagen."
                $kind = if ($k.Failed -gt 0) { 'warn' } else { 'ok' }
                Set-Status "Migration abgeschlossen – $($k.Ok) erfolgreich, $($k.Failed) fehlgeschlagen." $kind
                $ui.TxtMigrateSub.Text = 'Die Migration ist abgeschlossen.'
                $icon = if ($k.Failed -gt 0) { 'Warning' } else { 'Information' }
                [void][System.Windows.MessageBox]::Show($window,
                    "Migration abgeschlossen.`n`nErfolgreich migriert: $($k.Ok)`nFehlgeschlagen: $($k.Failed)",
                    'Sophos Geräte-Migration', 'OK', $icon)
            } elseif ((Get-Date) -gt $st.Deadline) {
                Stop-Polling "Zeitlimit erreicht – $($k.Open) Gerät(e) noch nicht abgeschlossen. Die Migration läuft serverseitig weiter."
                Set-Status "Zeitlimit erreicht – $($k.Open) Gerät(e) ausstehend (vermutlich offline)." 'warn'
                $ui.TxtMigrateSub.Text = 'Statusabfrage beendet. Ausstehende Geräte werden beim nächsten Check-in migriert.'
            } else {
                $st.NextPoll = (Get-Date).AddSeconds($script:PollIntervalSec)
            }
        }
        Update-PollInfo
    } -OnError {
        param($e)
        $st = $script:State
        $st.PollBusy = $false
        $ui.BtnRefreshStatus.IsEnabled = $true
        Write-Log "Statusabfrage fehlgeschlagen: $e"
        if ($st.Polling) { $st.NextPoll = (Get-Date).AddSeconds($script:PollIntervalSec) }
        Update-PollInfo
    }
}

function Update-PollInfo {
    $s = $script:State
    if (-not $s.Started) { $ui.TxtPollInfo.Text = ''; return }
    $last = if ($s.LastPoll) { 'Letzte Abfrage {0:HH:mm:ss}' -f $s.LastPoll } else { 'Noch keine Abfrage' }
    $ui.TxtPollInfo.Text =
        if ($s.PollBusy)    { 'Status wird abgefragt…' }
        elseif ($s.Polling) { "$last · nächste in $([Math]::Max(0, [int]($s.NextPoll - (Get-Date)).TotalSeconds)) s" }
        else                { "$last · automatische Abfrage beendet" }
}

function Export-MigrationResult {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CSV-Datei (*.csv)|*.csv'
    $dlg.FileName = 'Sophos-Migration_{0:yyyyMMdd-HHmm}.csv' -f (Get-Date)
    if (-not $dlg.ShowDialog($window)) { return }

    $jobId = $script:State.JobId
    try {
        $script:MigrationItems | ForEach-Object {
            [pscustomobject]@{
                Hostname           = $_.Hostname
                Betriebssystem     = $_.OS
                'Letzter Benutzer' = $_.LastUser
                Status             = $_.StatusText
                'Status (API)'     = $_.Status
                'Geräte-ID'        = $_.Id
                'Job-ID'           = $jobId
                Quelle             = $script:State.Src.Name
                Ziel               = $script:State.Dst.Name
            }
        } | Export-Csv -Path $dlg.FileName -NoTypeInformation -Delimiter ';' -Encoding UTF8
        Set-Status "Ergebnis exportiert: $($dlg.FileName)" 'ok'
        Write-Log "Ergebnis exportiert nach $($dlg.FileName)"
    } catch {
        Show-Error "Export fehlgeschlagen:`n$($_.Exception.Message)"
    }
}

# Sekundentakt: Countdown anzeigen und fällige Statusabfragen auslösen
$script:ClockTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ClockTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:ClockTimer.Add_Tick({
    $s = $script:State
    if ($s.Polling -and -not $s.PollBusy -and $s.NextPoll -and (Get-Date) -ge $s.NextPoll) { Invoke-StatusPoll }
    if ($s.Started) { Update-PollInfo }
})

# ============================================================================
#  Ereignisse
# ============================================================================

$ui.RbTenantKeys.Add_Checked({ Update-AuthPanels })
$ui.RbPartner.Add_Checked({ Update-AuthPanels })

$enterToLogin = {
    param($sender, $e)
    if ($e.Key -eq 'Return' -and -not (Test-Busy)) { $e.Handled = $true; Invoke-Login }
}
foreach ($n in 'TxtSrcId', 'PwdSrcSecret', 'TxtDstId', 'PwdDstSecret', 'TxtPartnerId', 'PwdPartnerSecret') {
    $ui[$n].Add_KeyDown($enterToLogin)
}

$ui.TxtSrcTenantSearch.Add_TextChanged({ $script:SrcTenantView.Refresh() })
$ui.TxtDstTenantSearch.Add_TextChanged({ $script:DstTenantView.Refresh() })
$ui.LstSrcTenants.Add_SelectionChanged({ Update-TenantWarning })
$ui.LstDstTenants.Add_SelectionChanged({ Update-TenantWarning })
$ui.LstDstTenants.Add_MouseDoubleClick({ if (Test-TenantSelection) { Confirm-Tenants } })

$ui.RbServer.Add_Checked({ $script:State.DeviceType = 'server'; Update-DeviceList })
$ui.RbClients.Add_Checked({ $script:State.DeviceType = 'computer'; Update-DeviceList })
$ui.BtnReload.Add_Click({
    if ($script:State.DeviceType) { Update-DeviceList } else { Show-Warning 'Bitte zuerst Server oder Clients wählen.' }
})
$ui.TxtDeviceSearch.Add_TextChanged({ $script:DeviceView.Refresh(); Update-SelectionInfo })
$ui.BtnSelectAll.Add_Click({ Set-DeviceSelection -Items $script:DeviceView -Value $true })
$ui.BtnSelectNone.Add_Click({ Set-DeviceSelection -Items $script:Devices -Value $false })

$ui.GridDevices.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -ne 'Space' -or $e.OriginalSource -is [System.Windows.Controls.CheckBox]) { return }
    $rows = @($ui.GridDevices.SelectedItems)
    if ($rows.Count -eq 0) { return }
    $e.Handled = $true
    $target = -not (@($rows | Where-Object { $_.IsSelected }).Count -eq $rows.Count)
    Set-DeviceSelection -Items $rows -Value $target
})
$ui.GridDevices.Add_MouseDoubleClick({
    $row = $ui.GridDevices.SelectedItem
    if ($row) { $row.IsSelected = -not $row.IsSelected }
})

$ui.BtnRefreshStatus.Add_Click({ Invoke-StatusPoll })
$ui.BtnStopPolling.Add_Click({
    Stop-Polling 'Automatische Statusabfrage beendet. Die Migration läuft serverseitig weiter.'
    Set-Status 'Statusabfrage beendet – die Migration läuft serverseitig weiter.' 'info'
})
$ui.BtnExport.Add_Click({ Export-MigrationResult })

$ui.BtnNext.Add_Click({
    if (Test-Busy) { return }
    switch ($script:State.Page) {
        1 { Invoke-Login }
        2 { Confirm-Tenants }
        3 { Show-MigrationPage }
        4 { if ($script:State.Started) { $window.Close() } else { Start-Migration } }
    }
})
$ui.BtnBack.Add_Click({
    switch ($script:State.Page) {
        2 { Show-Page 1 }
        3 { if ($script:State.Mode -eq 'partner') { Show-Page 2 } else { Show-Page 1 } }
        4 { Show-Page 3 }
    }
})

$window.Add_Closing({
    param($sender, $e)
    if ($script:State.Polling) {
        $answer = [System.Windows.MessageBox]::Show($window,
            "Die Statusabfrage läuft noch. Die Migration selbst läuft serverseitig weiter, auch wenn das Fenster geschlossen wird.`n`nFenster jetzt schließen?",
            'Sophos Geräte-Migration', 'YesNo', 'Question')
        if ("$answer" -ne 'Yes') { $e.Cancel = $true; return }
    }
    $script:ClockTimer.Stop()
    $script:BgTimer.Stop()
})

# ============================================================================
#  Start
# ============================================================================

$window.Title += "  ·  v$($script:AppVersion)"
$ui.HeaderSub.Text += "  ·  Version $($script:AppVersion)"
Show-Page 1
Update-AuthPanels
$script:ClockTimer.Start()
$window.Add_ContentRendered({ $ui.TxtSrcId.Focus() })
[void]$window.ShowDialog()

foreach ($task in @($script:BgTasks)) {
    try { $task.PS.Stop(); $task.PS.Runspace.Dispose(); $task.PS.Dispose() } catch { }
}
