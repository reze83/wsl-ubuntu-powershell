#Requires -Version 5.1
<#
.SYNOPSIS
    WSL2 Ubuntu Setup – Alles in einem Script

.DESCRIPTION
    Verwaltet WSL2 und Ubuntu vollstaendig aus einem einzigen PowerShell-Script.
    Aktiviert WSL2-Features, installiert Ubuntu, konfiguriert die Entwicklungsumgebung,
    und unterstuetzt Reset und Deinstallation.

.PARAMETER Action
    install   – WSL2-Features aktivieren und Ubuntu installieren (Standard)
    setup     – Ubuntu-Entwicklungsumgebung konfigurieren (laeuft in WSL)
    reset     – Ubuntu deregistrieren und neu installieren
    uninstall – Ubuntu deregistrieren
    status    – WSL-Status und verfuegbare Distros anzeigen

.PARAMETER Distribution
    Ubuntu-Distribution. Standard: Ubuntu-24.04
    Moegliche Werte: Ubuntu-24.04, Ubuntu-22.04, Ubuntu

.PARAMETER SetupMode
    minimal – Basis + Git + Shell + SSH
    full    – Alle Dev-Tools inkl. Python, Node.js (Standard)

.PARAMETER GitUserName
    Git user.name vorbelegen (optional)

.PARAMETER GitUserEmail
    Git user.email vorbelegen (optional)

.PARAMETER DryRun
    Zeigt geplante Schritte ohne Ausfuehrung

.PARAMETER RemoveWSLFeatures
    Nur bei 'uninstall': deaktiviert zusaetzlich die WSL2-Windows-Features
    (Microsoft-Windows-Subsystem-Linux, VirtualMachinePlatform).
    Nur wirksam wenn keine weiteren WSL-Distributionen installiert sind.
    Erfordert anschliessenden Neustart.

.EXAMPLE
    .\Setup-WSL.ps1
    .\Setup-WSL.ps1 install -Distribution Ubuntu-24.04
    .\Setup-WSL.ps1 setup -SetupMode minimal
    .\Setup-WSL.ps1 setup -GitUserName "Max Mustermann" -GitUserEmail "max@example.com"
    .\Setup-WSL.ps1 reset
    .\Setup-WSL.ps1 uninstall -RemoveWSLFeatures
    .\Setup-WSL.ps1 status
    .\Setup-WSL.ps1 install -DryRun
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Intentional: ANSI-colored terminal output requires Write-Host to avoid pipeline capture')]
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'setup', 'reset', 'uninstall', 'status')]
    [string]$Action = 'install',

    [ValidateSet('Ubuntu-24.04', 'Ubuntu-22.04', 'Ubuntu')]
    [string]$Distribution = 'Ubuntu-24.04',

    [ValidateSet('minimal', 'full')]
    [string]$SetupMode = 'full',

    [string]$GitUserName = '',
    [string]$GitUserEmail = '',

    [switch]$DryRun,
    [switch]$RemoveWSLFeatures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Farben & Ausgabe ──────────────────────────────────────────────────

$Script:C = @{
    Reset  = "`e[0m"
    Cyan   = "`e[36m"
    Green  = "`e[32m"
    Yellow = "`e[33m"
    Red    = "`e[31m"
    Dim    = "`e[2m"
    Bold   = "`e[1m"
}

$Script:TaskName = 'WSL-Setup-Resume'

function Write-Step   ([string]$Msg) { Write-Host "$($Script:C.Cyan)  >> $Msg$($Script:C.Reset)" }
function Write-Ok     ([string]$Msg) { Write-Host "$($Script:C.Green)  v  $Msg$($Script:C.Reset)" }
function Write-Warn   ([string]$Msg) { Write-Host "$($Script:C.Yellow)  !  $Msg$($Script:C.Reset)" }
function Write-Err    ([string]$Msg) { Write-Host "$($Script:C.Red)  x  $Msg$($Script:C.Reset)" }
function Write-Dim    ([string]$Msg) { Write-Host "$($Script:C.Dim)     $Msg$($Script:C.Reset)" }

#endregion

#region ── Banner ────────────────────────────────────────────────────────────

function Show-Banner {
    $dryLabel = if ($DryRun) { '  [DRY-RUN] Keine Aenderungen' } else { '' }
    Write-Host @"
$($Script:C.Cyan)
  ╔══════════════════════════════════════════════════════════╗
  ║              WSL2 Ubuntu Setup                          ║
  ╠══════════════════════════════════════════════════════════╣
  ║  Distribution : $($Distribution.PadRight(38))║
  ║  Aktion       : $($Action.PadRight(38))║
  ║  Modus        : $($SetupMode.PadRight(38))║
  ╚══════════════════════════════════════════════════════════╝$dryLabel
$($Script:C.Reset)
"@
}

#endregion

#region ── Scheduled Task (Resume nach Neustart) ─────────────────────────────

function Register-ResumeTask {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" install" +
               " -Distribution $Distribution -SetupMode $SetupMode"
    if ($GitUserName)  { $argList += " -GitUserName `"$GitUserName`"" }
    if ($GitUserEmail) { $argList += " -GitUserEmail `"$GitUserEmail`"" }

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

    Register-ScheduledTask -TaskName $Script:TaskName `
        -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal `
        -Description 'WSL2 Setup nach Neustart fortsetzen' -Force | Out-Null

    Write-Ok "Resume-Task registriert – Setup wird nach Neustart automatisch fortgesetzt"
}

function Remove-ResumeTask {
    if (Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false
        Write-Ok "Resume-Task entfernt"
    }
}

function Test-ResumeTaskExists {
    return $null -ne (Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue)
}

#endregion

#region ── Voraussetzungen ───────────────────────────────────────────────────

function Assert-WindowsVersion {
    $build = [System.Environment]::OSVersion.Version.Build
    if ($build -lt 19041) {
        Write-Err "Windows Build $build wird nicht unterstuetzt. Mindestens Build 19041 (Win10 v2004) benoetigt."
        exit 1
    }
    Write-Ok "Windows Build $build"
}

function Get-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-ElevatedIfNeeded {
    if (Get-IsAdmin) { return }

    Write-Warn "Administrator-Rechte benoetigt. Starte erhoehte PowerShell..."
    if ($DryRun) {
        Write-Dim "[DRY-RUN] wuerde Administrator-Shell starten"
        return
    }

    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", $Action)
    $argList += @("-Distribution", $Distribution, "-SetupMode", $SetupMode)
    if ($GitUserName)  { $argList += @("-GitUserName",  "`"$GitUserName`"") }
    if ($GitUserEmail) { $argList += @("-GitUserEmail", "`"$GitUserEmail`"") }
    if ($DryRun)       { $argList += "-DryRun" }

    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit 0
}

#endregion

#region ── WSL-Features aktivieren ──────────────────────────────────────────

function Enable-WSLFeatures {
    Write-Step "WSL2-Features pruefen und aktivieren..."

    $features = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
    $rebootNeeded = $false

    foreach ($feature in $features) {
        $state = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
        if ($state -and $state.State -eq 'Enabled') {
            Write-Ok "$feature bereits aktiv"
            continue
        }
        if ($DryRun) {
            Write-Dim "[DRY-RUN] Enable-WindowsOptionalFeature -FeatureName $feature"
            continue
        }
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart
        Write-Ok "$feature aktiviert"
        if ($result.RestartNeeded) { $rebootNeeded = $true }
    }

    if ($rebootNeeded -and -not $DryRun) {
        Write-Warn "Neustart erforderlich!"
        Register-ResumeTask
        $answer = Read-Host "  Jetzt neu starten? [J/n]"
        if ($answer -match '^[jJyY]?$') { Restart-Computer -Force }
        exit 0
    }
}

function Update-WSLKernel {
    Write-Step "WSL-Kernel auf aktuellen Stand bringen..."
    if ($DryRun) { Write-Dim "[DRY-RUN] wsl --update"; return }
    try {
        wsl --update 2>&1 | Out-Null
        Write-Ok "WSL-Kernel aktuell"
    } catch {
        Write-Warn "WSL-Kernel-Update nicht moeglich (kein Internet oder nicht verfuegbar)"
    }
}

function Set-WSLDefaultVersion {
    Write-Step "WSL2 als Standard-Version setzen..."
    if ($DryRun) { Write-Dim "[DRY-RUN] wsl --set-default-version 2"; return }
    wsl --set-default-version 2 2>&1 | Out-Null
    Write-Ok "WSL2 als Standard gesetzt"
}

function Disable-WSLFeatures {
    # Pruefen ob noch andere Distros ausser der gerade deregistrierten vorhanden sind
    $remaining = wsl --list --quiet 2>&1 | Where-Object { $_.Trim() -ne '' }
    if ($remaining.Count -gt 0) {
        Write-Warn "Weitere WSL-Distributionen vorhanden – WSL-Features bleiben aktiv:"
        $remaining | ForEach-Object { Write-Dim "    $_" }
        return
    }

    Write-Step "WSL2-Windows-Features deaktivieren..."
    $features = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')

    if ($DryRun) {
        $features | ForEach-Object { Write-Dim "[DRY-RUN] Disable-WindowsOptionalFeature -FeatureName $_" }
        return
    }

    foreach ($feature in $features) {
        $state = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
        if ($state -and $state.State -eq 'Enabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart | Out-Null
            Write-Ok "$feature deaktiviert"
        }
    }

    Write-Warn "Neustart erforderlich, um WSL-Features vollstaendig zu entfernen."
    $answer = Read-Host "  Jetzt neu starten? [J/n]"
    if ($answer -match '^[jJyY]?$') { Restart-Computer -Force }
}

#endregion

#region ── Ubuntu-Lifecycle ──────────────────────────────────────────────────

function Get-IsDistributionInstalled {
    $list = wsl --list --quiet 2>&1
    return ($list | Where-Object { $_ -match [regex]::Escape($Distribution) }).Count -gt 0
}

function Install-Ubuntu {
    Write-Step "$Distribution installieren..."

    if (Get-IsDistributionInstalled) {
        Write-Warn "$Distribution ist bereits installiert."
        Write-Dim "Nutze '.\Setup-WSL.ps1 reset' fuer eine Neuinstallation."
        return
    }

    if ($DryRun) {
        Write-Dim "[DRY-RUN] wsl --install -d $Distribution"
        return
    }

    Write-Host ""
    Write-Host "  Ubuntu wird jetzt installiert."
    Write-Host "  Nach dem ersten Start Ubuntu-Benutzerkonto anlegen:"
    Write-Host "    1. UNIX-Benutzernamen eingeben"
    Write-Host "    2. Passwort setzen"
    Write-Host "    3. 'exit' eingeben, um zurueckzukehren"
    Write-Host "  Danach: .\Setup-WSL.ps1 setup"
    Write-Host ""

    wsl --install -d $Distribution
    Write-Ok "$Distribution installiert"
}

function Invoke-UbuntuSetup {
    Write-Step "Ubuntu-Entwicklungsumgebung einrichten ($SetupMode)..."

    if (-not (Get-IsDistributionInstalled)) {
        Write-Err "$Distribution ist nicht installiert. Zuerst: .\Setup-WSL.ps1 install"
        exit 1
    }

    # Bash-Script neben diesem PS1 suchen
    $bashScript = Join-Path $PSScriptRoot 'ubuntu-wsl-setup.sh'
    if (-not (Test-Path $bashScript)) {
        Write-Err "ubuntu-wsl-setup.sh nicht gefunden: $bashScript"
        exit 1
    }

    # Windows-Pfad → WSL-Pfad konvertieren
    $resolved = (Resolve-Path $bashScript).Path
    $wslPath = if ($resolved -match '^([A-Za-z]):(.+)$') {
        '/mnt/' + $Matches[1].ToLower() + ($Matches[2] -replace '\\', '/')
    } else {
        $resolved -replace '\\', '/'
    }

    # Argumente aufbauen
    $setupArgs = "--$SetupMode"
    if ($GitUserName)  { $setupArgs += " --git-user-name `"$GitUserName`"" }
    if ($GitUserEmail) { $setupArgs += " --git-user-email `"$GitUserEmail`"" }
    if ($DryRun)       { $setupArgs += " --dry-run" }

    Write-Dim "Script : $wslPath"
    Write-Dim "Args   : $setupArgs"

    if ($DryRun) {
        Write-Dim "[DRY-RUN] wsl -d $Distribution bash -c 'chmod +x ... && bash ...'"
        return
    }

    wsl -d $Distribution bash -c "chmod +x '$wslPath' && bash '$wslPath' $setupArgs"
    Write-Ok "Ubuntu-Setup abgeschlossen"
}

function Reset-Ubuntu {
    Write-Step "$Distribution zuruecksetzen..."

    if (Get-IsDistributionInstalled) {
        $confirm = Read-Host "  $Distribution wirklich deregistrieren? Alle Daten gehen verloren! [J/n]"
        if ($confirm -notmatch '^[jJyY]?$') {
            Write-Warn "Abgebrochen."
            return
        }
        if ($DryRun) {
            Write-Dim "[DRY-RUN] wsl --unregister $Distribution"
        } else {
            wsl --unregister $Distribution
            Write-Ok "$Distribution deregistriert"
        }
    } else {
        Write-Warn "$Distribution war nicht installiert – starte direkt mit Installation."
    }

    Remove-ResumeTask
    Install-Ubuntu
}

function Remove-TerminalProfile {
    Write-Step "Windows Terminal Profile fuer '$Distribution' bereinigen..."

    $wtPaths = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
    )

    $found = $false
    foreach ($settingsPath in $wtPaths) {
        if (-not (Test-Path $settingsPath)) { continue }
        $found = $true

        if ($DryRun) {
            Write-Dim "[DRY-RUN] Profil '$Distribution' aus $(Split-Path $settingsPath -Leaf) entfernen"
            continue
        }

        try {
            $raw = Get-Content $settingsPath -Raw -Encoding UTF8
            # JSONC: Zeilen entfernen die nur Kommentare enthalten
            $stripped = ($raw -split '\r?\n' |
                Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
            $json = $stripped | ConvertFrom-Json

            if (-not ($json.profiles.PSObject.Properties.Name -contains 'list')) {
                Write-Dim "    keine Profil-Liste gefunden – uebersprungen"
                continue
            }

            $before = @($json.profiles.list)
            $after  = @($before | Where-Object {
                -not ($_.source -eq 'Windows.Terminal.Wsl' -and
                      $_.name   -like "*$Distribution*")
            })

            if ($after.Count -eq $before.Count) {
                Write-Dim "    kein gespeichertes Profil fuer '$Distribution' gefunden"
                continue
            }

            $json.profiles.list = $after
            Copy-Item $settingsPath "$settingsPath.bak" -Force
            $json | ConvertTo-Json -Depth 20 | Set-Content $settingsPath -Encoding UTF8
            Write-Ok "$($before.Count - $after.Count) Profil(e) entfernt – Backup: $(Split-Path $settingsPath -Leaf).bak"
        }
        catch {
            Write-Warn "settings.json nicht bearbeitbar: $_"
        }
    }

    if (-not $found) {
        Write-Dim "Windows Terminal nicht gefunden – kein Profil-Cleanup noetig"
    }
}

function Remove-Ubuntu {
    Write-Step "$Distribution deinstallieren..."

    if (-not (Get-IsDistributionInstalled)) {
        Write-Warn "$Distribution ist nicht installiert."
        Remove-ResumeTask
        return
    }

    $confirm = Read-Host "  $Distribution wirklich deregistrieren? Alle Daten gehen verloren! [J/n]"
    if ($confirm -notmatch '^[jJyY]?$') {
        Write-Warn "Abgebrochen."
        return
    }

    if ($DryRun) {
        Write-Dim "[DRY-RUN] wsl --unregister $Distribution"
        Remove-TerminalProfile
        if ($RemoveWSLFeatures) { Write-Dim "[DRY-RUN] Disable-WSLFeatures" }
        return
    }

    wsl --unregister $Distribution
    Write-Ok "$Distribution deregistriert"
    Remove-ResumeTask
    Remove-TerminalProfile

    if ($RemoveWSLFeatures) {
        Disable-WSLFeatures
    }
}

#endregion

#region ── Status ────────────────────────────────────────────────────────────

function Show-WSLStatus {
    Write-Host ""
    Write-Host "$($Script:C.Cyan)  WSL-Status:$($Script:C.Reset)"
    Write-Host ""
    try {
        wsl --status 2>&1 | ForEach-Object { Write-Host "    $_" }
    } catch {
        Write-Warn "wsl --status nicht verfuegbar"
    }

    Write-Host ""
    Write-Host "$($Script:C.Cyan)  Installierte Distributionen:$($Script:C.Reset)"
    Write-Host ""
    wsl --list --verbose 2>&1 | ForEach-Object { Write-Host "    $_" }
    Write-Host ""

    Write-Host "$($Script:C.Cyan)  Verfuegbare Ubuntu-Versionen:$($Script:C.Reset)"
    Write-Host ""
    try {
        wsl --list --online 2>&1 | Where-Object { $_ -match 'Ubuntu' } |
            ForEach-Object { Write-Host "    $_" }
    } catch {
        Write-Warn "Keine Online-Liste verfuegbar"
    }
    Write-Host ""
}

#endregion

#region ── Main ──────────────────────────────────────────────────────────────

Show-Banner

switch ($Action) {
    'install' {
        Assert-WindowsVersion
        Invoke-ElevatedIfNeeded
        Enable-WSLFeatures
        Update-WSLKernel
        Set-WSLDefaultVersion
        Install-Ubuntu
        Remove-ResumeTask
        Write-Host ""
        Write-Ok "Installation abgeschlossen!"
        Write-Host ""
        Write-Host "  Naechste Schritte:"
        Write-Host "  1. Ubuntu starten und Benutzerkonto anlegen (falls noch nicht geschehen)"
        Write-Host "  2. Entwicklungsumgebung einrichten:"
        Write-Dim  "     .\Setup-WSL.ps1 setup"
        Write-Host ""
    }
    'setup' {
        Invoke-UbuntuSetup
    }
    'reset' {
        Invoke-ElevatedIfNeeded
        Reset-Ubuntu
    }
    'uninstall' {
        Invoke-ElevatedIfNeeded
        Remove-Ubuntu
    }
    'status' {
        Show-WSLStatus
    }
}

#endregion
