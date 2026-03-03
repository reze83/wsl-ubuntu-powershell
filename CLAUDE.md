# wsl-ubuntu-powershell

## Übersicht
Automatisierungsscript zum Einrichten und Verwalten von Ubuntu unter WSL2 auf Windows.
Ein PowerShell-Einstiegspunkt (`Setup-WSL.ps1`) steuert den gesamten Workflow,
vom WSL2-Feature-Aktivieren bis zur vollständig konfigurierten Entwicklungsumgebung.

## Dateien

| Datei | Zweck |
|-------|-------|
| `Setup-WSL.ps1` | **Haupt-Script** – alle WSL-Lifecycle-Operationen |
| `ubuntu-wsl-setup.sh` | Ubuntu-Konfiguration (self-contained, wird von PS1 aufgerufen) |

## Verwendung

```powershell
# Ubuntu installieren (WSL2-Features aktivieren + Ubuntu-24.04 installieren)
.\Setup-WSL.ps1

# Ubuntu-Entwicklungsumgebung konfigurieren (nach erstem Login)
.\Setup-WSL.ps1 setup

# Minimal-Setup (nur Basis + Git + Shell + SSH)
.\Setup-WSL.ps1 setup -SetupMode minimal

# Git-Daten vorbelegen
.\Setup-WSL.ps1 setup -GitUserName "Max Mustermann" -GitUserEmail "max@example.com"

# Ubuntu neu installieren (alle Daten gelöscht!)
.\Setup-WSL.ps1 reset

# WSL-Status anzeigen
.\Setup-WSL.ps1 status

# Alles simulieren ohne Änderungen
.\Setup-WSL.ps1 install -DryRun
.\Setup-WSL.ps1 setup -DryRun
```

## Actions (Setup-WSL.ps1)

| Action | Beschreibung |
|--------|-------------|
| `install` | WSL2-Features aktivieren, Ubuntu-24.04 installieren (Standard) |
| `setup` | ubuntu-wsl-setup.sh in WSL ausführen |
| `reset` | Ubuntu deregistrieren + neu installieren |
| `uninstall` | Ubuntu deregistrieren |
| `status` | WSL-Status + installierte Distros anzeigen |

## ubuntu-wsl-setup.sh – Modi

| Modus | Installiert |
|-------|-------------|
| `--minimal` | System-Update, Basis-Pakete, Locale, wsl.conf, Git, Shell, SSH |
| `--full` (Standard) | + CLI-Tools, Dev-Dependencies, Python+uv, Node.js+pnpm, tmux |

## Anforderungen
- Windows 10 Build 19041 (v2004) oder neuer / Windows 11
- PowerShell 5.1+
- Internet-Verbindung
- Administrator-Rechte (für WSL-Feature-Aktivierung)

## Konventionen
- PowerShell: `Set-StrictMode -Version Latest`, PSScriptAnalyzer-kompatibel
- Bash: `set -euo pipefail`, shellcheck-kompatibel
- Dry-Run via `-DryRun` (PS) / `--dry-run` (Bash)

## Wichtige Befehle
- Bash-Lint: `shellcheck ubuntu-wsl-setup.sh`
- PS-Lint: `Invoke-ScriptAnalyzer -Path Setup-WSL.ps1`
- Dry-Run: `.\Setup-WSL.ps1 install -DryRun`
