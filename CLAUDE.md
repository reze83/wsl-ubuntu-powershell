# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# wsl-ubuntu-powershell

Automatisierungsscript zum Einrichten und Verwalten von Ubuntu unter WSL2 auf Windows.
Ein PowerShell-Einstiegspunkt steuert den gesamten Lifecycle; ein self-contained Bash-Script
konfiguriert die Ubuntu-Umgebung innerhalb von WSL.

## Dateien

| Datei | Zweck |
|-------|-------|
| `Setup-WSL.ps1` | **Einziger Einstiegspunkt** – alle WSL-Lifecycle-Operationen |
| `ubuntu-wsl-setup.sh` | Ubuntu-Konfiguration (self-contained, keine lib/-Abhängigkeiten) |

## Actions (Setup-WSL.ps1)

| Action | Parameter | Beschreibung |
|--------|-----------|-------------|
| `install` (Standard) | `-Distribution`, `-DryRun` | WSL2-Features aktivieren, Ubuntu installieren, Scheduled Task für Auto-Resume nach Reboot |
| `setup` | `-SetupMode`, `-GitUserName`, `-GitUserEmail`, `-DryRun` | ubuntu-wsl-setup.sh in WSL ausführen |
| `reset` | `-Distribution` | Ubuntu deregistrieren + sofort neu installieren |
| `uninstall` | `-RemoveWSLFeatures` | Ubuntu deregistrieren, WT-Profile bereinigen; mit `-RemoveWSLFeatures` auch WSL2-Windows-Features deaktivieren (nur wenn keine anderen Distros vorhanden) |
| `status` | – | WSL-Status + installierte Distros anzeigen |

## ubuntu-wsl-setup.sh – Modi

| Modus | Installiert |
|-------|-------------|
| `--minimal` | System-Update, Basis-Pakete, Locale, wsl.conf, Git, Shell (zsh+Oh-My-Zsh), SSH |
| `--full` (Standard) | + CLI-Tools (eza, zoxide, bat, fd, ripgrep, gh), Dev-Deps, Python+uv, Node.js+pnpm, tmux |

## Wichtige Befehle

```powershell
# Lint
shellcheck ubuntu-wsl-setup.sh
Invoke-ScriptAnalyzer -Path Setup-WSL.ps1

# Dry-Run (kein Schreiben, zeigt alle Schritte)
.\Setup-WSL.ps1 install -DryRun
.\Setup-WSL.ps1 setup -DryRun
.\Setup-WSL.ps1 uninstall -RemoveWSLFeatures -DryRun
```

## Architektur-Entscheidungen

**Scheduled Task (WSL-Setup-Resume):**
`install` registriert beim ersten Neustart-Bedarf automatisch einen `AtLogOn`-Task
(erhöhte Rechte, aktueller User). Nach erfolgreichem Abschluss entfernt `Remove-ResumeTask`
den Task. `reset` und `uninstall` räumen den Task ebenfalls auf.

**Windows Terminal Profil-Cleanup:**
`uninstall` entfernt manuell gespeicherte WT-Profile via `Remove-TerminalProfile`.
Die Funktion parst `settings.json` beider WT-Varianten (Stable + Preview) nach
`source=Windows.Terminal.Wsl`-Einträgen. Da settings.json JSONC ist, werden
Kommentarzeilen vor `ConvertFrom-Json` gefiltert. Backup: `settings.json.bak`.

**WSL-Feature-Deaktivierung:**
Nur explizit via `-RemoveWSLFeatures` + nur wenn danach keine anderen Distros verbleiben.
`reset` deaktiviert WSL-Features bewusst nicht (Reinstall folgt direkt).

## Konventionen

- PowerShell: `Set-StrictMode -Version Latest`, PSScriptAnalyzer-kompatibel
- Bash: `set -euo pipefail`, shellcheck-kompatibel
- Dry-Run: jede Funktion prüft `$DryRun` / `--dry-run` und schreibt nur `Write-Dim "[DRY-RUN] ..."` statt zu handeln
- Farb-Ausgabe: `$Script:C`-Hashtable mit ANSI-Codes; Hilfsfunktionen `Write-Step/Ok/Warn/Err/Dim`

## Anforderungen

- Windows 10 Build 19041 (v2004) oder neuer / Windows 11
- PowerShell 5.1+
- Administrator-Rechte (für WSL-Feature-Aktivierung und Scheduled Tasks)
