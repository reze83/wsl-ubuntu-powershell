# wsl-ubuntu-powershell

## Übersicht
Automatisierungsscripts zum Einrichten und Verwalten von Ubuntu unter WSL2 auf Windows.
Kombiniert PowerShell-Scripts für den WSL-Lifecycle mit einem umfangreichen Bash-Setup-Script.

## Architektur
- Sprache: PowerShell (.ps1) + Bash (.sh)
- Einstiegspunkt: `ubuntu-wsl-setup.sh` (Bash) bzw. nummerierte `.ps1`-Scripts (PowerShell)
- Lib-Dateien: `lib/logging.sh`, `lib/packages.sh`, `lib/config.sh`, `lib/tools.sh`

## Script-Reihenfolge (PowerShell)
1. `0_enable_wsl.ps1`     – WSL-Feature aktivieren
2. `1_download_ubuntu.ps1` – Ubuntu-Image herunterladen
3. `2_install_ubuntu.ps1`  – Ubuntu installieren + PATH setzen
4. `3_reset_ubuntu.ps1`    – Ubuntu zurücksetzen
5. `4_uninstall_ubuntu.ps1` – Ubuntu deinstallieren

## ubuntu-wsl-setup.sh – Modi
```bash
./ubuntu-wsl-setup.sh --minimal    # Basis + Git + Shell + SSH
./ubuntu-wsl-setup.sh --full       # alles inkl. CLI, Dev, Python, Node.js
./ubuntu-wsl-setup.sh --dry-run    # Vorschau ohne Ausführung
./ubuntu-wsl-setup.sh --git-user-name "Name" --git-user-email "mail@example.com"
./ubuntu-wsl-setup.sh --ssh-key-email "mail@example.com"
```

## Konventionen
- Bash: `set -euo pipefail` in allen Scripts
- Bash: `shellcheck` für Linting verwenden
- PowerShell: PSScriptAnalyzer für Linting
- Lib-Dateien werden via `source` geladen – Pfade relativ zu `SCRIPT_DIR`
- Keine interaktiven Prompts (non-interactive-safe)

## Wichtige Befehle
- Lint Bash: `shellcheck ubuntu-wsl-setup.sh lib/*.sh`
- Lint PowerShell: `Invoke-ScriptAnalyzer -Path .`
- Dry-Run testen: `bash ubuntu-wsl-setup.sh --dry-run`
