#!/bin/bash
#===============================================================================
# Ubuntu WSL2 Setup - Optimierte Entwicklungsumgebung
# Verwendung: chmod +x ubuntu-wsl-setup.sh && ./ubuntu-wsl-setup.sh
# Optionen:   ./ubuntu-wsl-setup.sh --minimal    (Basis + Git + Shell + SSH)
#             ./ubuntu-wsl-setup.sh --full        (alles inkl. CLI, Dev, Python, Node.js)
#             ./ubuntu-wsl-setup.sh --dry-run     (zeigt Schritte ohne Ausfuehrung)
#             ./ubuntu-wsl-setup.sh --git-user-name "Max Mustermann" --git-user-email "max@example.com"
#             ./ubuntu-wsl-setup.sh --ssh-key-email "max@example.com"
#             ./ubuntu-wsl-setup.sh --help        (Hilfe anzeigen)
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Script Directory & Lib Loading
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=lib/packages.sh
source "${SCRIPT_DIR}/lib/packages.sh"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"

#-------------------------------------------------------------------------------
# Konfiguration (used by sourced lib/ files)
#-------------------------------------------------------------------------------
# shellcheck disable=SC2034
{
  readonly MODE_MINIMAL="--minimal"
  readonly MODE_FULL="--full"
  readonly MODE_DEFAULT="$MODE_FULL"
  readonly LOG_FILE="$HOME/.wsl-setup.log"
  readonly NVM_VERSION="0.40.1"
  readonly NODE_VERSION="lts/*"
  readonly LOCAL_BIN_DIR="$HOME/.local/bin"
  readonly PIP_CONFIG_DIR="$HOME/.config/pip"
  readonly PIP_CONFIG_FILE="$PIP_CONFIG_DIR/pip.conf"
  readonly BASHRC_PATH="$HOME/.bashrc"
  readonly SSH_DIR="$HOME/.ssh"
  readonly SSH_CONFIG="$SSH_DIR/config"
  readonly SSH_KEY="$SSH_DIR/id_ed25519"
  readonly WSL_CONF_FILE="/etc/wsl.conf"
}

INSTALL_MODE="$MODE_DEFAULT"
DRY_RUN=false
GIT_USER_NAME=""
GIT_USER_EMAIL=""
SSH_KEY_EMAIL=""

#-------------------------------------------------------------------------------
# CLI Argument Parsing
#-------------------------------------------------------------------------------
is_valid_email() {
  local email="$1"

  [[ -z "$email" ]] && return 0

  if [[ ${#email} -gt 254 ]]; then
    return 1
  fi

  if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    return 1
  fi

  if [[ "$email" == *..* ]]; then
    return 1
  fi

  local local_part="${email%@*}"
  local domain_part="${email#*@}"

  if [[ "$local_part" == .* || "$local_part" == *. ]]; then
    return 1
  fi

  if [[ "$domain_part" == .* || "$domain_part" == *. ]]; then
    return 1
  fi

  return 0
}

assert_valid_email_or_exit() {
  local value="$1"
  local option_name="$2"

  if ! is_valid_email "$value"; then
    print_error "Ungueltige E-Mail-Adresse fuer $option_name: $value"
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --minimal) INSTALL_MODE="$MODE_MINIMAL" ;;
      --full) INSTALL_MODE="$MODE_FULL" ;;
      --dry-run) DRY_RUN=true ;;
      --git-user-name)
        shift
        if [[ -z "${1:-}" ]]; then
          print_error "Fehlender Wert fuer --git-user-name"
          exit 1
        fi
        GIT_USER_NAME="$1"
        ;;
      --git-user-email)
        shift
        if [[ -z "${1:-}" ]]; then
          print_error "Fehlender Wert fuer --git-user-email"
          exit 1
        fi
        GIT_USER_EMAIL="$1"
        assert_valid_email_or_exit "$GIT_USER_EMAIL" "--git-user-email"
        ;;
      --ssh-key-email)
        shift
        if [[ -z "${1:-}" ]]; then
          print_error "Fehlender Wert fuer --ssh-key-email"
          exit 1
        fi
        SSH_KEY_EMAIL="$1"
        assert_valid_email_or_exit "$SSH_KEY_EMAIL" "--ssh-key-email"
        ;;
      --help | -h)
        show_help
        exit 0
        ;;
      *)
        print_error "Unbekannte Option: $1"
        show_help
        exit 1
        ;;
    esac
    shift
  done
}

#-------------------------------------------------------------------------------
# Hilfsfunktionen
#-------------------------------------------------------------------------------
ensure_user_symlink() {
  local source_bin="$1"
  local target_bin="$2"

  if command -v "$source_bin" &>/dev/null && [[ ! -e "$LOCAL_BIN_DIR/$target_bin" ]]; then
    mkdir -p "$LOCAL_BIN_DIR"
    ln -sf "$(command -v "$source_bin")" "$LOCAL_BIN_DIR/$target_bin"
  fi
}

#-------------------------------------------------------------------------------
# SSH-Key-Generierung
#-------------------------------------------------------------------------------
generate_ssh_key_if_missing() {
  if [[ -f "$SSH_KEY" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    return 0
  fi

  local email="${SSH_KEY_EMAIL:-${GIT_USER_EMAIL:-}}"
  local reply
  read -r -p "  SSH-Key generieren? [J/n]: " reply
  reply="${reply:-j}"
  if [[ "${reply,,}" != "j" && "${reply,,}" != "y" ]]; then
    return 0
  fi

  print_step "SSH-Key generieren... (Enter = keine Passphrase, empfohlen: sichere Passphrase eingeben)"
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  ssh-keygen -t ed25519 -C "${email:-$(whoami)@$(hostname)}" -f "$SSH_KEY"
  print_success "SSH-Key erstellt: $SSH_KEY"
  printf '\n  %bPublic Key (fuer GitHub/GitLab unter Settings → SSH Keys einfuegen):%b\n' "$CYAN" "$NC"
  printf '  %s\n\n' "$(cat "${SSH_KEY}.pub")"
}

#-------------------------------------------------------------------------------
# Error Handler
#-------------------------------------------------------------------------------
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    print_error "Setup fehlgeschlagen (Exit: $exit_code)"
    print_dim "Log: $LOG_FILE"
  fi
}
trap cleanup EXIT

#-------------------------------------------------------------------------------
# Pre-flight Checks
#-------------------------------------------------------------------------------
preflight_checks() {
  if [[ $EUID -eq 0 ]]; then
    print_error "Nicht als root ausfuehren! Verwende normalen User."
    exit 1
  fi

  if ! grep -qi microsoft /proc/version 2>/dev/null; then
    print_warning "Nicht in WSL2 — einige Features deaktiviert"
  fi

  local required_cmd
  local -a required_cmds=(sudo apt-get curl git)
  for required_cmd in "${required_cmds[@]}"; do
    if ! command -v "$required_cmd" &>/dev/null; then
      print_error "Benoetigter Befehl fehlt: $required_cmd"
      exit 1
    fi
  done

  if ! sudo -n true 2>/dev/null; then
    print_step "Sudo-Berechtigung wird geprueft..."
    sudo -v
  fi
}

collect_identity_inputs() {
  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  if [[ ! -t 0 ]]; then
    return
  fi

  print_step "Benutzerdaten (am Anfang)"

  if [[ -z "$GIT_USER_NAME" ]]; then
    read -r -p "  Git Benutzername (optional): " GIT_USER_NAME
  fi

  if [[ -z "$GIT_USER_EMAIL" ]]; then
    while true; do
      read -r -p "  Git E-Mail (optional): " GIT_USER_EMAIL
      if is_valid_email "$GIT_USER_EMAIL"; then
        break
      fi
      print_warning "Ungueltige E-Mail-Adresse. Bitte erneut eingeben."
    done
  fi

  if [[ -z "$SSH_KEY_EMAIL" ]]; then
    while true; do
      if [[ -n "$GIT_USER_EMAIL" ]]; then
        read -r -p "  SSH-Key E-Mail (Enter = $GIT_USER_EMAIL): " SSH_KEY_EMAIL
        if [[ -z "$SSH_KEY_EMAIL" ]]; then
          SSH_KEY_EMAIL="$GIT_USER_EMAIL"
        fi
      else
        read -r -p "  SSH-Key E-Mail (optional): " SSH_KEY_EMAIL
      fi

      if is_valid_email "$SSH_KEY_EMAIL"; then
        break
      fi

      print_warning "Ungueltige E-Mail-Adresse. Bitte erneut eingeben."
      SSH_KEY_EMAIL=""
    done
  fi
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
  cat <<'EOF_HELP'
Ubuntu WSL2 Setup - Optimierte Entwicklungsumgebung

VERWENDUNG:
  ./ubuntu-wsl-setup.sh [OPTIONEN]

OPTIONEN:
  --minimal            Basis-System + Git + Shell + SSH (ohne Dev-Tools)
  --full               Alles installieren (Standard)
  --dry-run            Zeigt geplante Schritte ohne Ausfuehrung
  --git-user-name N    Git user.name vorbelegen (optional)
  --git-user-email E   Git user.email vorbelegen (optional)
  --ssh-key-email E    E-Mail fuer SSH-Key-Hinweis vorbelegen (optional)
  --help, -h           Diese Hilfe anzeigen

MODI:
  --minimal installiert:
    - System-Update, Basis-Pakete, Locale, WSL-Config, Sysctl
    - Git-Konfiguration (+ Credential Helper), Shell, Readline, SSH

  --full installiert zusaetzlich:
    - CLI-Tools (ripgrep, fzf, fd, bat, tmux, ncdu, eza, zoxide, gh, direnv)
    - Browser-Integration (wslview)
    - Dev-Dependencies (Compiler, Debugger, Linter, DB-Clients)
    - Python + uv
    - Node.js (via nvm) + pnpm
    - tmux-Konfiguration
EOF_HELP
}

#-------------------------------------------------------------------------------
# Banner
#-------------------------------------------------------------------------------
show_banner() {
  printf '%b' "$CYAN"
  cat <<'EOF_BANNER'
  _   _ _                 _          ____       _
 | | | | |__  _   _ _ __ | |_ _   _ / ___|  ___| |_ _   _ _ __
 | | | | '_ \| | | | '_ \| __| | | | \___ \ / _ \ __| | | | '_ \
 | |_| | |_) | |_| | | | | |_| |_| |  ___) |  __/ |_| |_| | |_) |
  \___/|_.__/ \__,_|_| |_|\__|\__,_| |____/ \___|\__|\__,_| .__/
                                                          |_|
EOF_BANNER
  printf '%b\n' "$NC"
  printf '%b  Mode: %s | Log: %s%b\n' "$DIM" "$INSTALL_MODE" "$LOG_FILE" "$NC"
  if [[ "$DRY_RUN" == true ]]; then
    printf '%b  [DRY-RUN] Keine Aenderungen werden durchgefuehrt%b\n' "$YELLOW" "$NC"
  fi
  printf '\n'
}

#-------------------------------------------------------------------------------
# Dry-Run Support
#-------------------------------------------------------------------------------
show_dry_run_plan() {
  print_step "Geplante Schritte (Dry-Run):"
  echo ""
  echo "  Immer:"
  echo "    1. System aktualisieren (apt update/upgrade)"
  echo "    2. Basis-Pakete installieren ($(wc -w <<<"$(load_packages BASE "${SCRIPT_DIR}/config/packages.conf")" 2>/dev/null || echo '?') Pakete)"
  echo "    3. Locale konfigurieren (en_US.UTF-8, de_DE.UTF-8)"
  echo "    4. /etc/wsl.conf erstellen"
  echo "    5. Kernel-Parameter optimieren (vm.swappiness=10)"
  echo "    6. Git konfigurieren (+ Credential Helper)"
  echo "    7. Shell optimieren (.bashrc)"
  echo "    8. Readline konfigurieren (~/.inputrc)"
  echo "    9. SSH einrichten"

  if [[ "$INSTALL_MODE" == "$MODE_FULL" ]]; then
    echo ""
    echo "  Full-Mode zusaetzlich:"
    echo "    10. CLI-Tools (ripgrep, fzf, fd, bat, tmux, ncdu, eza, zoxide, gh, direnv)"
    echo "    11. Browser-Integration (xdg-utils, wslu)"
    echo "    12. Dev-Dependencies (Compiler, Debugger, DB-Clients, ...)"
    echo "    13. Python + uv"
    echo "    14. Node.js (nvm) + pnpm"
    echo "    15. tmux konfigurieren (~/.tmux.conf)"
  fi

  echo ""
  print_dim "Zum Ausfuehren ohne --dry-run starten"
}

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
show_summary() {
  local py_version
  py_version=$(python3 --version 2>/dev/null | cut -d' ' -f2)

  printf '\n%b' "$GREEN"
  cat <<'EOF_SUMMARY'
===============================================================================
                         Setup abgeschlossen!
===============================================================================
EOF_SUMMARY
  printf '%b\n' "$NC"

  printf '  Installiert:\n'
  printf '    %b+%b Kernel-Parameter (vm.swappiness=10)\n' "$GREEN" "$NC"
  printf '    %b+%b Git, Shell-Optimierungen, Readline, SSH\n' "$GREEN" "$NC"
  if command -v python3 &>/dev/null; then
    printf '    %b+%b Python %s\n' "$GREEN" "$NC" "$py_version"
  fi
  if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    local node_version
    node_version=$(. "$HOME/.nvm/nvm.sh" && node --version 2>/dev/null)
    printf '    %b+%b Node.js %s\n' "$GREEN" "$NC" "$node_version"
  fi
  if [[ "$INSTALL_MODE" == "$MODE_FULL" ]]; then
    printf '    %b+%b CLI-Tools (inkl. eza, zoxide, gh, direnv), Browser-Integration\n' "$GREEN" "$NC"
    printf '    %b+%b Dev-Dependencies (Lint/Test, Build, Debug, DB, HTTP)\n' "$GREEN" "$NC"
    printf '    %b+%b tmux konfiguriert\n' "$GREEN" "$NC"
  fi

  printf '\n  Naechste Schritte:\n\n'
  printf '  1. WSL neu starten (in PowerShell auf Windows ausfuehren, nicht hier):\n'
  printf '     %bwsl --shutdown%b\n\n' "$CYAN" "$NC"
  if [[ -n "${GIT_USER_NAME:-}" || -n "${GIT_USER_EMAIL:-}" ]]; then
    printf '  2. Git konfiguriert:\n'
    [[ -n "${GIT_USER_NAME:-}" ]] && printf '     Name:  %b%s%b\n' "$CYAN" "$GIT_USER_NAME" "$NC"
    [[ -n "${GIT_USER_EMAIL:-}" ]] && printf '     Email: %b%s%b\n\n' "$CYAN" "$GIT_USER_EMAIL" "$NC"
  else
    printf '  2. Git-Benutzer setzen (optional):\n'
    printf '     %bgit config --global user.name "Dein Name"%b\n' "$CYAN" "$NC"
    printf '     %bgit config --global user.email "deine@email.com"%b\n\n' "$CYAN" "$NC"
  fi

  if [[ -f "$SSH_KEY" ]]; then
    printf '  3. SSH-Key vorhanden: %b%s.pub%b\n\n' "$CYAN" "$SSH_KEY" "$NC"
  else
    local display_ssh_email="${SSH_KEY_EMAIL:-${GIT_USER_EMAIL:-deine@email.com}}"
    printf '  3. SSH-Key generieren (optional):\n'
    printf '     %bssh-keygen -t ed25519 -C "%s"%b\n\n' "$CYAN" "$display_ssh_email" "$NC"
  fi
  printf '  Log: %b%s%b\n\n' "$DIM" "$LOG_FILE" "$NC"
  printf '===============================================================================\n\n'
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
  parse_args "$@"
  show_banner
  preflight_checks
  collect_identity_inputs
  assert_valid_email_or_exit "$GIT_USER_EMAIL" "Git E-Mail"
  assert_valid_email_or_exit "$SSH_KEY_EMAIL" "SSH-Key E-Mail"

  if [[ "$DRY_RUN" == true ]]; then
    show_dry_run_plan
    exit 0
  fi

  : >"$LOG_FILE"
  log "=== Setup gestartet: $INSTALL_MODE ==="

  # Basis (beide Modi)
  system_update
  install_base_packages
  setup_locale
  setup_wsl_conf
  setup_sysctl
  setup_git
  setup_shell
  setup_inputrc
  setup_ssh

  generate_ssh_key_if_missing

  # Full-Mode Extras
  if [[ "$INSTALL_MODE" == "$MODE_FULL" ]]; then
    install_cli_tools
    install_browser_integration
    install_dev_dependencies
    setup_python
    setup_nodejs
    setup_tmux
  fi

  log "=== Setup beendet ==="
  show_summary
}

main "$@"
