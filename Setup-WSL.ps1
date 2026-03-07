#Requires -Version 5.1
<#
.SYNOPSIS
    WSL2 Ubuntu Setup – Alles in einem Script

.DESCRIPTION
    Verwaltet WSL2 und Ubuntu vollstaendig aus einem einzigen PowerShell-Script.
    Aktiviert WSL2-Features, installiert Ubuntu, konfiguriert die Entwicklungsumgebung,
    und unterstuetzt Reset und Deinstallation.

    Wird das Script ohne explizite Parameter aufgerufen und laeuft in einer
    interaktiven Terminal-Session, startet automatisch ein deutschsprachiger
    Einrichtungsassistent, der alle nötigen Einstellungen abfragt.

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

.PARAMETER SshKeyEmail
    E-Mail-Adresse fuer SSH-Key-Generierung (optional, Standard: GitUserEmail)

.PARAMETER DryRun
    Zeigt geplante Schritte ohne Ausfuehrung

.PARAMETER RemoveWSLFeatures
    Nur bei 'uninstall': deaktiviert zusaetzlich die WSL2-Windows-Features
    (Microsoft-Windows-Subsystem-Linux, VirtualMachinePlatform).
    Nur wirksam wenn keine weiteren WSL-Distributionen installiert sind.
    Erfordert anschliessenden Neustart.

.PARAMETER Interactive
    Erzwingt den interaktiven Einrichtungsassistenten auch wenn er nicht
    automatisch erkannt wird (z.B. in ConEmu oder anderen Terminal-Emulatoren).
    Mit -Interactive:$false wird der Assistent immer deaktiviert.

.NOTES
    Exit-Codes:
      0  – Erfolgreich abgeschlossen
      1  – Fehler aufgetreten
      2  – Benutzer hat abgebrochen / destruktive Operation im nicht-interaktiven Modus
      3  – Neustart erforderlich (non-interaktiver Modus, kein Auto-Resume moeglich)

.EXAMPLE
    .\Setup-WSL.ps1
    Startet den interaktiven Assistenten (wenn in Terminal-Session)

    .\Setup-WSL.ps1 -Interactive
    Erzwingt den interaktiven Assistenten

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
    [string]$SshKeyEmail = '',

    [switch]$DryRun,
    [switch]$RemoveWSLFeatures,
    [switch]$Interactive,
    [switch]$KeepWindowOpenInternal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ExplicitParams = @{}
foreach ($k in $PSBoundParameters.Keys) {
    $Script:ExplicitParams[$k] = $PSBoundParameters[$k]
}

#region ── Farben & Ausgabe ──────────────────────────────────────────────────

$Script:C = @{
    Reset  = "$([char]27)[0m"
    Cyan   = "$([char]27)[36m"
    Green  = "$([char]27)[32m"
    Yellow = "$([char]27)[33m"
    Red    = "$([char]27)[31m"
    Dim    = "$([char]27)[2m"
    Bold   = "$([char]27)[1m"
}

$Script:TaskName = 'WSL-Setup-Resume'

function Write-Step   ([string]$Msg) { Write-Host "$($Script:C.Cyan)  >> $Msg$($Script:C.Reset)" }
function Write-Ok     ([string]$Msg) { Write-Host "$($Script:C.Green)  v  $Msg$($Script:C.Reset)" }
function Write-Warn   ([string]$Msg) { Write-Host "$($Script:C.Yellow)  !  $Msg$($Script:C.Reset)" }
function Write-Err    ([string]$Msg) { Write-Host "$($Script:C.Red)  x  $Msg$($Script:C.Reset)" }
function Write-Dim    ([string]$Msg) { Write-Host "$($Script:C.Dim)     $Msg$($Script:C.Reset)" }

function Test-IsExplorerLaunchContext {
    if ([Environment]::GetCommandLineArgs() -match '-NonInteractive') { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ($Host.Name -ne 'ConsoleHost') { return $false }

    try {
        $pidNow = [int]$PID
        for ($depth = 0; $depth -lt 6; $depth++) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$pidNow" -ErrorAction Stop
            if (-not $proc) { break }

            $name = [string]$proc.Name
            if ($name -ieq 'explorer.exe') { return $true }

            $parentId = [int]$proc.ParentProcessId
            if ($parentId -le 0 -or $parentId -eq $pidNow) { break }
            $pidNow = $parentId
        }
    } catch {
        return $false
    }

    return $false
}

function Test-ShouldPauseOnExit {
    if ([Environment]::GetCommandLineArgs() -match '-NonInteractive') { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ($Host.Name -ne 'ConsoleHost') { return $false }

    if ($KeepWindowOpenInternal.IsPresent) { return $true }
    if ($Script:ExplorerLaunch) { return $true }
    return $false
}

function Exit-Script {
    param(
        [int]$Code = 0,
        [switch]$ForcePause,
        [switch]$NoPause
    )

    $shouldPause = $false
    if (-not $NoPause) {
        if ($ForcePause) {
            $shouldPause = $true
        } else {
            $shouldPause = Test-ShouldPauseOnExit
        }
    }

    if ($shouldPause) {
        Write-Host ""
        Write-Host "Druecken Sie eine beliebige Taste zum Beenden..." -ForegroundColor DarkGray
        try {
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        } catch {
            # Fallback: Exit trotzdem sicher durchfuehren
        }
    }

    exit $Code
}

#endregion

#region ── Interaktiver Wizard ────────────────────────────────────────────────

function Test-IsInteractiveSession {
    if ($Script:ExplicitParams.ContainsKey('Interactive')) {
        return $Interactive.IsPresent
    }
    if ([Environment]::GetCommandLineArgs() -match '-NonInteractive') { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if (Test-ResumeTaskExists) { return $false }
    try {
        if ([Console]::WindowHeight -le 0) { return $false }
    } catch { return $false }
    return $true
}

function Test-ParamExplicit([string]$Name) {
    return $Script:ExplicitParams.ContainsKey($Name)
}

function Prompt-Choice {
    param(
        [string]$Label,
        [string[]]$Options,
        [string]$Default = '',
        [hashtable]$Descriptions = @{}
    )

    Write-Host ""
    Write-Host "$($Script:C.Cyan)  $Label$($Script:C.Reset)"

    for ($i = 0; $i -lt $Options.Length; $i++) {
        $num = $i + 1
        $opt = $Options[$i]
        $isDefault = ($opt -eq $Default)
        $marker = $(if ($isDefault) { "$($Script:C.Green)>" } else { " " })
        $numStr = "[$num]"
        $desc = $(if ($Descriptions.ContainsKey($opt)) { " - $($Descriptions[$opt])" } else { "" })
        Write-Host "  $marker $numStr $opt$desc$($Script:C.Reset)"
    }

    $defaultHint = $(if ($Default) { " (Enter = $Default)" } else { "" })
    Write-Host ""

    $selected = $null
    while ($null -eq $selected) {
        $raw = Read-Host "  Auswahl$defaultHint"

        if ($raw -eq '') {
            if ($Default -ne '') {
                $selected = $Default
            } else {
                Write-Warn "Bitte eine Auswahl treffen."
            }
        } elseif ($raw -match '^\d+$') {
            $idx = [int]$raw - 1
            if ($idx -ge 0 -and $idx -lt $Options.Length) {
                $selected = $Options[$idx]
            } else {
                Write-Warn "Ungueltige Nummer. Bitte zwischen 1 und $($Options.Length) waehlen."
            }
        } else {
            $match = $Options | Where-Object { $_ -eq $raw } | Select-Object -First 1
            if ($match) {
                $selected = $match
            } else {
                Write-Warn "Ungueltige Eingabe. Nummer (1-$($Options.Length)) oder Option direkt eingeben."
            }
        }
    }

    return $selected
}

function Prompt-Text {
    param(
        [string]$Label,
        [string]$Default = '',
        [switch]$AllowEmpty,
        [string]$Hint = ''
    )

    $hintStr = ''
    if ($Hint) {
        $hintStr = " $($Script:C.Dim)($Hint)$($Script:C.Reset)"
    }
    $defaultHint = ''
    if ($Default) {
        $defaultHint = " $($Script:C.Dim)(Enter = $Default)$($Script:C.Reset)"
    }

    $result = $null
    while ($null -eq $result) {
        Write-Host ""
        $raw = Read-Host "  $Label$hintStr$defaultHint"

        if ($raw -eq '') {
            if ($Default -ne '') {
                $result = $Default
            } elseif ($AllowEmpty) {
                $result = ''
            } else {
                Write-Warn "Eingabe erforderlich."
            }
        } else {
            $result = $raw
        }
    }

    return $result
}

function Prompt-Confirm {
    param(
        [string]$Label,
        [bool]$Default = $true,
        [switch]$Destructive
    )

    if (-not $Script:IsInteractive) {
        if ($Destructive) {
            Write-Err "Destruktive Operation im nicht-interaktiven Modus nicht erlaubt: $Label"
            Exit-Script 2
        }
        return $Default
    }

    $hint = $(if ($Default) { '[J/n]' } else { '[j/N]' })
    $labelDisplay = $(if ($Destructive) {
        "$($Script:C.Red)$Label$($Script:C.Reset)"
    } else {
        $Label
    })

    while ($true) {
        Write-Host ""
        $raw = Read-Host "  $labelDisplay $hint"

        if ($raw -eq '') { return $Default }
        if ($raw -match '^[jJyY]$') { return $true }
        if ($raw -match '^[nN]$') { return $false }

        if ($Destructive) {
            Write-Warn "Bitte 'j' oder 'n' eingeben."
        } else {
            return $Default
        }
    }
}

function Start-InteractiveWizard {
    Write-Host ""
    Write-Host "$($Script:C.Cyan)$($Script:C.Bold)  Einrichtungsassistent$($Script:C.Reset)"
    Write-Host "$($Script:C.Dim)  Alle Fragen mit Enter bestaetigen um den Standard zu nutzen.$($Script:C.Reset)"

    # 1. Action
    if (-not (Test-ParamExplicit 'Action')) {
        $actionDescs = @{
            'install'   = 'WSL2-Features aktivieren und Ubuntu installieren'
            'setup'     = 'Ubuntu-Entwicklungsumgebung konfigurieren'
            'reset'     = 'Ubuntu deregistrieren und neu installieren'
            'uninstall' = 'Ubuntu deregistrieren'
            'status'    = 'WSL-Status und verfuegbare Distros anzeigen'
        }
        $script:Action = Prompt-Choice -Label 'Aktion:' `
            -Options @('install', 'setup', 'reset', 'uninstall', 'status') `
            -Default 'install' `
            -Descriptions $actionDescs
    }

    # 2. Distribution (skip for status)
    if (-not (Test-ParamExplicit 'Distribution') -and $script:Action -ne 'status') {
        $script:Distribution = Prompt-Choice -Label 'Distribution:' `
            -Options @('Ubuntu-24.04', 'Ubuntu-22.04', 'Ubuntu') `
            -Default 'Ubuntu-24.04'
    }

    # 3. SetupMode (only for install/setup)
    if (-not (Test-ParamExplicit 'SetupMode') -and ($script:Action -eq 'install' -or $script:Action -eq 'setup')) {
        $modeDescs = @{
            'full'    = 'Alle Dev-Tools inkl. Python, Node.js (empfohlen)'
            'minimal' = 'Basis + Git + Shell + SSH (fuer Server/CI)'
        }
        $script:SetupMode = Prompt-Choice -Label 'Setup-Modus:' `
            -Options @('full', 'minimal') `
            -Default 'full' `
            -Descriptions $modeDescs
    }

    # 4. GitUserName (only for install/setup)
    if (-not (Test-ParamExplicit 'GitUserName') -and ($script:Action -eq 'install' -or $script:Action -eq 'setup')) {
        $script:GitUserName = Prompt-Text -Label 'Git Name:' `
            -Default $script:GitUserName `
            -AllowEmpty `
            -Hint 'optional, z.B. Max Mustermann'
    }

    # 5. GitUserEmail (only for install/setup)
    if (-not (Test-ParamExplicit 'GitUserEmail') -and ($script:Action -eq 'install' -or $script:Action -eq 'setup')) {
        $script:GitUserEmail = Prompt-Text -Label 'Git E-Mail:' `
            -Default $script:GitUserEmail `
            -AllowEmpty `
            -Hint 'optional, z.B. max@example.com'
    }

    # 6. SshKeyEmail (only when GitUserEmail is set, for install/setup)
    if (-not (Test-ParamExplicit 'SshKeyEmail') -and ($script:Action -eq 'install' -or $script:Action -eq 'setup') -and $script:GitUserEmail -ne '') {
        $sshDefault = $(if ($script:SshKeyEmail) { $script:SshKeyEmail } else { $script:GitUserEmail })
        $script:SshKeyEmail = Prompt-Text -Label 'SSH-Key E-Mail:' `
            -Default $sshDefault `
            -AllowEmpty `
            -Hint 'fuer SSH-Key-Generierung'
    }

    # 7. RemoveWSLFeatures (only for uninstall)
    if (-not (Test-ParamExplicit 'RemoveWSLFeatures') -and $script:Action -eq 'uninstall') {
        $removeFeatures = Prompt-Confirm -Label 'WSL2-Windows-Features ebenfalls deaktivieren?' -Default $false
        if ($removeFeatures) {
            $script:RemoveWSLFeatures = [switch]::Present
        }
    }
}

function Show-Summary {
    $boxWidth = 60
    $innerWidth = $boxWidth - 4  # for "  ║ " and " ║"

    $dryPrefix = $(if ($DryRun) { '[DRY-RUN] ' } else { '' })
    $actionDisplay = "$dryPrefix$($script:Action)"

    function Format-Row([string]$key, [string]$value, [string]$color = '') {
        $label = $key.PadRight(14)
        $maxVal = $innerWidth - $label.Length - 3  # ": " and padding
        if ($value.Length -gt $maxVal) {
            $value = $value.Substring(0, $maxVal - 3) + '...'
        }
        $paddedValue = $value.PadRight($maxVal)
        $colorStart = $(if ($color) { $color } else { '' })
        $colorEnd   = $(if ($color) { $Script:C.Reset } else { '' })
        return "  $($Script:C.Cyan)║$($Script:C.Reset)  ${label}: $colorStart$paddedValue$colorEnd  $($Script:C.Cyan)║$($Script:C.Reset)"
    }

    Write-Host ""
    Write-Host "$($Script:C.Cyan)  ╔$('═' * ($boxWidth - 2))╗$($Script:C.Reset)"
    Write-Host "$($Script:C.Cyan)  ║$($Script:C.Reset)$($Script:C.Bold)$((' Zusammenfassung').PadRight($boxWidth - 2))$($Script:C.Cyan)║$($Script:C.Reset)"
    Write-Host "$($Script:C.Cyan)  ╠$('═' * ($boxWidth - 2))╣$($Script:C.Reset)"

    $actionColor = $(if ($DryRun) { $Script:C.Yellow } else { $Script:C.Bold })
    Write-Host (Format-Row 'Aktion' $actionDisplay $actionColor)

    if ($script:Action -ne 'status') {
        Write-Host (Format-Row 'Distribution' $script:Distribution)
    }

    if ($script:Action -eq 'install' -or $script:Action -eq 'setup') {
        Write-Host (Format-Row 'Setup-Modus' $script:SetupMode)
        if ($script:GitUserName) {
            Write-Host (Format-Row 'Git Name' $script:GitUserName)
        }
        if ($script:GitUserEmail) {
            Write-Host (Format-Row 'Git E-Mail' $script:GitUserEmail)
        }
        if ($script:SshKeyEmail) {
            Write-Host (Format-Row 'SSH-Key E-Mail' $script:SshKeyEmail)
        }
    }

    if ($script:Action -eq 'uninstall' -and $script:RemoveWSLFeatures) {
        Write-Host (Format-Row 'WSL-Features' 'werden deaktiviert' $Script:C.Red)
    }

    Write-Host "$($Script:C.Cyan)  ╚$('═' * ($boxWidth - 2))╝$($Script:C.Reset)"
    Write-Host ""
}

#endregion

#region ── Banner ────────────────────────────────────────────────────────────

function Show-Banner {
    $dryLabel = ''
    if ($DryRun) { $dryLabel = '  [DRY-RUN] Keine Aenderungen' }
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
    if ($DryRun) { Write-Dim "[DRY-RUN] Register-ResumeTask"; return }
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" install" +
               " -Distribution $Distribution -SetupMode $SetupMode"
    if ($GitUserName)  { $argList += " -GitUserName '"  + ($GitUserName  -replace "'", "''") + "'" }
    if ($GitUserEmail) { $argList += " -GitUserEmail '" + ($GitUserEmail -replace "'", "''") + "'" }
    if ($SshKeyEmail)  { $argList += " -SshKeyEmail '"  + ($SshKeyEmail  -replace "'", "''") + "'" }
    # NOTE: -Interactive intentionally omitted – scheduled task always runs non-interactive

    try {
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -ErrorAction Stop
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
        Register-ScheduledTask -TaskName $Script:TaskName `
            -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal `
            -Description 'WSL2 Setup nach Neustart fortsetzen' -Force | Out-Null
        Write-Ok "Resume-Task registriert – Setup wird nach Neustart automatisch fortgesetzt"
    } catch {
        Write-Warn "Resume-Task konnte nicht registriert werden: $_"
        Write-Warn "Nach Neustart manuell fortsetzen: .\Setup-WSL.ps1 setup -Distribution $Distribution"
    }
}

function Remove-ResumeTask {
    if ($DryRun) { Write-Dim "[DRY-RUN] Remove-ResumeTask"; return }
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
        Exit-Script 1
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
    if ($GitUserName)  { $argList += @("-GitUserName",  "'" + ($GitUserName  -replace "'", "''") + "'") }
    if ($GitUserEmail) { $argList += @("-GitUserEmail", "'" + ($GitUserEmail -replace "'", "''") + "'") }
    if ($SshKeyEmail)  { $argList += @("-SshKeyEmail",  "'" + ($SshKeyEmail  -replace "'", "''") + "'") }
    if ($RemoveWSLFeatures) { $argList += "-RemoveWSLFeatures" }
    if ($Script:ExplicitParams.ContainsKey('Interactive')) { $argList += "-Interactive:`$$($Interactive.IsPresent)" }
    if ($KeepWindowOpenInternal -or $Script:ExplorerLaunch) { $argList += "-KeepWindowOpenInternal" }

    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Err "UAC-Elevation fehlgeschlagen oder abgebrochen: $_"
        Exit-Script 1
    }
    Exit-Script 0 -NoPause
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
        try {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart -ErrorAction Stop
            Write-Ok "$feature aktiviert"
        } catch {
            Write-Err "Feature $feature konnte nicht aktiviert werden: $_"
            Exit-Script 1
        }
        if ($result.RestartNeeded) { $rebootNeeded = $true }
    }

    if ($rebootNeeded -and -not $DryRun) {
        Write-Warn "Neustart erforderlich!"
        if ($Script:IsInteractive) {
            if (Prompt-Confirm -Label 'Jetzt neu starten?' -Default $true) {
                Register-ResumeTask
                try {
                    Restart-Computer -Force -ErrorAction Stop
                } catch {
                    Remove-ResumeTask
                    Write-Err "Neustart fehlgeschlagen: $_"
                    Write-Warn "Resume-Task wurde entfernt. Bitte manuell neu starten und danach: .\Setup-WSL.ps1 install"
                    Exit-Script 1
                }
            }
            Write-Warn "Kein Neustart – bitte manuell neu starten und dann: .\Setup-WSL.ps1 install"
            Exit-Script 0
        } else {
            Register-ResumeTask
            Write-Warn "Nicht-interaktiver Modus: Neustart-Task registriert. Bitte manuell neu starten."
            Exit-Script 3
        }
    }
}

function Update-WSLKernel {
    Write-Step "WSL-Kernel auf aktuellen Stand bringen..."
    if ($DryRun) { Write-Dim "[DRY-RUN] wsl --update"; return }
    $updateOutput = wsl --update 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "WSL-Kernel aktuell"
    } else {
        Write-Warn "WSL-Kernel-Update nicht moeglich: $($updateOutput -join ' ')"
    }
}

function Set-WSLDefaultVersion {
    Write-Step "WSL2 als Standard-Version setzen..."
    if ($DryRun) { Write-Dim "[DRY-RUN] wsl --set-default-version 2"; return }
    $output = wsl --set-default-version 2 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "WSL2 als Standard gesetzt"
    } else {
        Write-Warn "WSL2 als Standard-Version konnte nicht gesetzt werden: $($output -join ' ')"
    }
}

function Set-WSLConfig {
    Write-Step ".wslconfig optimieren..."

    $wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'

    # System-Specs ermitteln
    $totalRamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $totalCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $allocRamGB = [math]::Max(4, [math]::Floor($totalRamGB / 2))
    $allocCores = [math]::Max(2, $totalCores - 1)
    $swapGB     = [math]::Max(2, [math]::Floor($totalRamGB / 4))

    $configContent = @"
# WSL2 Globale Konfiguration
# Generiert von Setup-WSL.ps1 am $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# System: ${totalRamGB}GB RAM, ${totalCores} Cores

[wsl2]
memory=${allocRamGB}GB
processors=$allocCores
swap=${swapGB}GB
nestedVirtualization=true
debugConsole=false
guiApplications=true
gpuSupport=true

[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
networkingMode=mirrored
dnsTunneling=true
firewall=true
autoProxy=true
hostAddressLoopback=true
"@

    if ($DryRun) {
        Write-Dim "[DRY-RUN] $wslConfigPath erstellen:"
        $configContent -split "`n" | ForEach-Object { Write-Dim "  $_" }
        return
    }

    if (Test-Path $wslConfigPath) {
        Write-Warn ".wslconfig existiert bereits: $wslConfigPath"
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        if ($Script:IsInteractive) {
            if (Prompt-Confirm -Label 'Backup erstellen und ueberschreiben?' -Default $true) {
                $backupPath = "${wslConfigPath}.${ts}.bak"
                Copy-Item -Path $wslConfigPath -Destination $backupPath -Force
                Write-Ok "Backup: $backupPath"
            } else {
                Write-Warn ".wslconfig nicht geaendert"
                return
            }
        } else {
            $backupPath = "${wslConfigPath}.${ts}.bak"
            Copy-Item -Path $wslConfigPath -Destination $backupPath -Force
            Write-Ok "Backup: $backupPath"
        }
    }

    [System.IO.File]::WriteAllText($wslConfigPath, $configContent.Replace("`r`n", "`n"))
    Write-Ok ".wslconfig erstellt (${allocRamGB}GB RAM, $allocCores Cores, networkingMode=mirrored)"
}

function Disable-WSLFeatures {
    # Pruefen ob noch andere Distros ausser der gerade deregistrierten vorhanden sind
    # UTF-16 LE Encoding fuer wsl.exe Output in PS 5.1 setzen
    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    $remaining = @(wsl --list --quiet 2>&1 | Where-Object { $_.Trim() -ne '' })
    [Console]::OutputEncoding = $prevEncoding
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
    if ($Script:IsInteractive) {
        if (Prompt-Confirm -Label 'Jetzt neu starten?' -Default $true) {
            try {
                Restart-Computer -Force -ErrorAction Stop
            } catch {
                Write-Err "Neustart fehlgeschlagen: $_"
                Write-Warn "Bitte manuell neu starten."
            }
        }
    } else {
        Write-Warn "Nicht-interaktiver Modus: Bitte manuell neu starten."
        Exit-Script 3
    }
}

#endregion

#region ── Ubuntu-Lifecycle ──────────────────────────────────────────────────

function Get-IsDistributionInstalled {
    # UTF-16 LE Encoding fuer wsl.exe Output in PS 5.1 setzen
    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    $list = wsl --list --quiet 2>&1
    [Console]::OutputEncoding = $prevEncoding
    return @($list | Where-Object { ($_ -replace '\0', '').Trim() -eq $Distribution }).Count -gt 0
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
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$Distribution konnte nicht installiert werden (Exit-Code: $LASTEXITCODE)"
        Exit-Script 1
    }
    Write-Ok "$Distribution installiert"
}

function Invoke-UbuntuSetup {
    Write-Step "Ubuntu-Entwicklungsumgebung einrichten ($SetupMode)..."

    if (-not (Get-IsDistributionInstalled)) {
        Write-Err "$Distribution ist nicht installiert. Zuerst: .\Setup-WSL.ps1 install"
        Exit-Script 1
    }

    # Bash-Script neben diesem PS1 suchen
    $bashScript = Join-Path $PSScriptRoot 'ubuntu-wsl-setup.sh'
    if (-not (Test-Path $bashScript)) {
        Write-Err "ubuntu-wsl-setup.sh nicht gefunden: $bashScript"
        Exit-Script 1
    }

    # Windows-Pfad → WSL-Pfad konvertieren
    $resolved = (Resolve-Path $bashScript).Path
    if ($resolved -match '^([A-Za-z]):(.+)$') {
        $wslPath = '/mnt/' + $Matches[1].ToLower() + ($Matches[2] -replace '\\', '/')
    } else {
        $wslPath = $resolved -replace '\\', '/'
    }

    # Argumente als Array aufbauen (kein String-Interpolation, kein Shell-Injection-Risiko)
    $wslArgs = @('-d', $Distribution, '--', 'bash', $wslPath, "--$SetupMode")
    if ($GitUserName)  { $wslArgs += @('--git-user-name',  $GitUserName) }
    if ($GitUserEmail) { $wslArgs += @('--git-user-email', $GitUserEmail) }
    if ($SshKeyEmail)  { $wslArgs += @('--ssh-key-email',  $SshKeyEmail) }
    if ($DryRun)       { $wslArgs += '--dry-run' }

    Write-Dim "Script : $wslPath"
    Write-Dim "Args   : $($wslArgs -join ' ')"

    if ($DryRun) {
        Write-Dim "[DRY-RUN] wsl $($wslArgs -join ' ')"
        return
    }

    & wsl @wslArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Ubuntu-Setup fehlgeschlagen (Exit-Code: $LASTEXITCODE)"
        Exit-Script 1
    }
    Write-Ok "Ubuntu-Setup abgeschlossen"
}

function Reset-Ubuntu {
    Write-Step "$Distribution zuruecksetzen..."

    if (Get-IsDistributionInstalled) {
        if (-not (Prompt-Confirm -Label "$Distribution wirklich deregistrieren? Alle Daten gehen verloren!" -Default $false -Destructive)) {
            Write-Warn "Abgebrochen."
            return
        }
        if ($DryRun) {
            Write-Dim "[DRY-RUN] wsl --unregister $Distribution"
        } else {
            wsl --unregister $Distribution
            if ($LASTEXITCODE -ne 0) {
                Write-Err "wsl --unregister fehlgeschlagen (Exit-Code: $LASTEXITCODE)"
                Exit-Script 1
            }
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

            [object[]]$before = @($json.profiles.list)
            [object[]]$after  = @($before | Where-Object {
                -not ($_.source -eq 'Windows.Terminal.Wsl' -and
                      $_.name   -like "*$Distribution*")
            })

            if ($after.Count -eq $before.Count) {
                Write-Dim "    kein gespeichertes Profil fuer '$Distribution' gefunden"
                continue
            }

            $json.profiles.list = [object[]]@($after)
            $ts = (Get-Date -Format 'yyyyMMdd-HHmmss')
            $bakPath = "$settingsPath.$ts.bak"
            Copy-Item $settingsPath $bakPath -Force
            $jsonStr = $json | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($settingsPath, $jsonStr, [System.Text.UTF8Encoding]::new($false))
            Write-Ok "$($before.Count - $after.Count) Profil(e) entfernt – Backup: $(Split-Path $bakPath -Leaf)"
        }
        catch {
            Write-Warn "settings.json nicht bearbeitbar: $_"
            Write-Warn "WT-Profil fuer '$Distribution' konnte nicht automatisch entfernt werden."
            Write-Dim "  Bitte manuell unter: Windows Terminal → Einstellungen → Profile"
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
        if ($RemoveWSLFeatures) { Disable-WSLFeatures }
        return
    }

    if (-not (Prompt-Confirm -Label "$Distribution wirklich deregistrieren? Alle Daten gehen verloren!" -Default $false -Destructive)) {
        Write-Warn "Abgebrochen."
        return
    }

    if ($DryRun) {
        Write-Dim "[DRY-RUN] wsl --unregister $Distribution"
        Remove-ResumeTask
        Remove-TerminalProfile
        if ($RemoveWSLFeatures) { Write-Dim "[DRY-RUN] Disable-WSLFeatures" }
        return
    }

    wsl --unregister $Distribution
    if ($LASTEXITCODE -ne 0) {
        Write-Err "wsl --unregister fehlgeschlagen (Exit-Code: $LASTEXITCODE)"
        Exit-Script 1
    }
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

$Script:ExplorerLaunch = Test-IsExplorerLaunchContext
$Script:IsInteractive = Test-IsInteractiveSession

if ($Script:IsInteractive) {
    Start-InteractiveWizard
}

Show-Banner

if ($Script:IsInteractive) {
    Show-Summary
    if (-not $DryRun -and $Action -ne 'status') {
        if (-not (Prompt-Confirm -Label 'Ausfuehren?' -Default $true)) {
            Write-Warn "Abgebrochen."
            Exit-Script 2
        }
    }
}

switch ($Action) {
    'install' {
        Assert-WindowsVersion
        Invoke-ElevatedIfNeeded
        Enable-WSLFeatures
        Update-WSLKernel
        Set-WSLDefaultVersion
        Set-WSLConfig
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

$pauseAtEnd = $Script:IsInteractive -and $Host.Name -eq 'ConsoleHost'
Exit-Script 0 -ForcePause:$pauseAtEnd

#endregion
