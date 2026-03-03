# WSL Ubuntu Setup — Demo
# Aufnehmen mit: vhs demo.tape
# Voraussetzung: vhs installiert (https://github.com/charmbracelet/vhs)
#                WSL + Ubuntu-24.04 eingerichtet + ubuntu-wsl-setup.sh im CWD

Output docs/demo.gif

Set Shell bash
Set FontSize 13
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

Sleep 500ms

# --- Schritt 1: Dry-Run zeigt alle geplanten Schritte ---
Type "# Schritt 1: Dry-Run — zeigt alle Aktionen ohne Ausführung"
Enter
Sleep 800ms

Type "DRY_RUN=true bash ubuntu-wsl-setup.sh --full 2>&1 | head -50"
Enter
Sleep 6s

# --- Schritt 2: Validierung nach echtem Setup ---
Type "# Schritt 2: Validierung (136 Checks)"
Enter
Sleep 800ms

Type "bash ubuntu-wsl-validate.sh 2>&1 | tail -12"
Enter
Sleep 5s
