#!/bin/bash
#===============================================================================
# Ubuntu WSL2 Setup – Optimierte Entwicklungsumgebung
#
# Verwendung:
#   chmod +x ubuntu-wsl-setup.sh && ./ubuntu-wsl-setup.sh
#
# Optionen:
#   --minimal            Basis + Git + Shell + SSH
#   --full               Alles inkl. Dev-Tools, Python, Node.js (Standard)
#   --dry-run            Zeigt geplante Schritte ohne Ausfuehrung
#   --git-user-name N    Git user.name vorbelegen
#   --git-user-email E   Git user.email vorbelegen
#   --ssh-key-email E    E-Mail fuer SSH-Key vorbelegen
#   --help, -h           Diese Hilfe
#
# Wird normalerweise von Setup-WSL.ps1 automatisch aufgerufen.
#===============================================================================

set -euo pipefail


#-------------------------------------------------------------------------------
# Farben
#-------------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly CYAN='\033[0;36m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

#-------------------------------------------------------------------------------
# Konfiguration
#-------------------------------------------------------------------------------
readonly MODE_MINIMAL="--minimal"
readonly MODE_FULL="--full"
readonly MODE_DEFAULT="$MODE_FULL"
readonly LOG_FILE="$HOME/.wsl-setup.log"
readonly NVM_VERSION="0.40.4"
readonly NODE_VERSION="lts/*"
readonly LOCAL_BIN_DIR="$HOME/.local/bin"
readonly BASHRC_PATH="$HOME/.bashrc"
readonly SSH_DIR="$HOME/.ssh"
readonly SSH_CONFIG="$SSH_DIR/config"
readonly SSH_KEY="$SSH_DIR/id_ed25519"
readonly WSL_CONF_FILE="/etc/wsl.conf"

# shellcheck disable=SC2034
INSTALL_MODE="$MODE_DEFAULT"
DRY_RUN=false
GIT_USER_NAME=""
GIT_USER_EMAIL=""
SSH_KEY_EMAIL=""

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------
log()           { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
print_step()    { printf '\n%b  >> %s%b\n' "$CYAN" "$*" "$NC";   log "STEP: $*"; }
print_success() { printf '%b  v  %s%b\n'  "$GREEN" "$*" "$NC";   log "OK:   $*"; }
print_warning() { printf '%b  !  %s%b\n'  "$YELLOW" "$*" "$NC";  log "WARN: $*"; }
print_error()   { printf '%b  x  %s%b\n'  "$RED" "$*" "$NC" >&2; log "ERR:  $*"; }
print_dim()     { printf '%b     %s%b\n'  "$DIM" "$*" "$NC"; }

#-------------------------------------------------------------------------------
# Hilfsfunktionen
#-------------------------------------------------------------------------------

# Zeile zu Datei hinzufuegen, wenn Marker noch nicht vorhanden
append_if_missing() {
  local file="$1" marker="$2"
  shift 2
  local content="$*"
  grep -qF "$marker" "$file" 2>/dev/null || printf '\n%s\n' "$content" >> "$file"
}

ensure_user_symlink() {
  local source_bin="$1" target_bin="$2"
  if command -v "$source_bin" &>/dev/null && [[ ! -e "$LOCAL_BIN_DIR/$target_bin" ]]; then
    mkdir -p "$LOCAL_BIN_DIR"
    ln -sf "$(command -v "$source_bin")" "$LOCAL_BIN_DIR/$target_bin"
  fi
}

#-------------------------------------------------------------------------------
# CLI Argument Parsing
#-------------------------------------------------------------------------------
is_valid_email() {
  local email="$1"
  [[ -z "$email" ]] && return 0
  [[ ${#email} -gt 254 ]] && return 1
  [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && return 1
  [[ "$email" == *..* ]] && return 1
  local local_part="${email%@*}"
  local domain_part="${email#*@}"
  [[ "$local_part" == .* || "$local_part" == *. ]] && return 1
  [[ "$domain_part" == .* || "$domain_part" == *. ]] && return 1
  return 0
}

_validate_installer_script() {
  local file="$1" label="$2"
  if [[ ! -s "$file" ]]; then
    print_warning "$label: heruntergeladenes Script ist leer"
    return 1
  fi
  if ! head -1 "$file" | grep -qE '^#!'; then
    print_warning "$label: heruntergeladenes Script hat keinen Shebang"
    return 1
  fi
  return 0
}

assert_valid_email_or_exit() {
  local value="$1" option_name="$2"
  if ! is_valid_email "$value"; then
    local safe_value
    safe_value=$(printf '%s' "$value" | tr -cd '[:print:]')
    print_error "Ungueltige E-Mail-Adresse fuer $option_name: $safe_value"
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --minimal) INSTALL_MODE="$MODE_MINIMAL" ;;
      --full)    INSTALL_MODE="$MODE_FULL" ;;
      --dry-run) DRY_RUN=true ;;
      --git-user-name)
        shift
        [[ -z "${1:-}" ]] && { print_error "Fehlender Wert fuer --git-user-name"; exit 1; }
        GIT_USER_NAME="$1"
        ;;
      --git-user-email)
        shift
        [[ -z "${1:-}" ]] && { print_error "Fehlender Wert fuer --git-user-email"; exit 1; }
        GIT_USER_EMAIL="$1"
        assert_valid_email_or_exit "$GIT_USER_EMAIL" "--git-user-email"
        ;;
      --ssh-key-email)
        shift
        [[ -z "${1:-}" ]] && { print_error "Fehlender Wert fuer --ssh-key-email"; exit 1; }
        SSH_KEY_EMAIL="$1"
        assert_valid_email_or_exit "$SSH_KEY_EMAIL" "--ssh-key-email"
        ;;
      --help|-h) show_help; exit 0 ;;
      *) print_error "Unbekannte Option: $1"; show_help; exit 1 ;;
    esac
    shift
  done
}

#-------------------------------------------------------------------------------
# System-Update
#-------------------------------------------------------------------------------
system_update() {
  print_step "System aktualisieren..."
  if [[ "$DRY_RUN" == true ]]; then print_dim "[DRY-RUN] apt-get update + full-upgrade"; return; fi
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>> "$LOG_FILE"; then
    print_error "apt-get update fehlgeschlagen"
    exit 1
  fi
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq 2>> "$LOG_FILE"; then
    print_error "apt-get full-upgrade fehlgeschlagen"
    exit 1
  fi
  print_success "System aktuell"
}

#-------------------------------------------------------------------------------
# Basis-Pakete
#-------------------------------------------------------------------------------
install_base_packages() {
  print_step "Basis-Pakete installieren..."
  local -a packages=(
    curl wget git gnupg2 ca-certificates
    apt-transport-https software-properties-common
    lsb-release locales unzip zip
    build-essential pkg-config
    openssh-client
  )
  if [[ "$DRY_RUN" == true ]]; then
    print_dim "[DRY-RUN] apt install: ${packages[*]}"
    return
  fi
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" 2>> "$LOG_FILE"; then
    print_error "Basis-Pakete: Installation fehlgeschlagen"
    exit 1
  fi
  print_success "Basis-Pakete (${#packages[@]}) installiert"
}

#-------------------------------------------------------------------------------
# Locale
#-------------------------------------------------------------------------------
setup_locale() {
  print_step "Locale konfigurieren..."
  if [[ "$DRY_RUN" == true ]]; then print_dim "[DRY-RUN] locale-gen en_US.UTF-8 de_DE.UTF-8"; return; fi
  if ! sudo locale-gen en_US.UTF-8 de_DE.UTF-8 2>> "$LOG_FILE"; then
    print_warning "locale-gen fehlgeschlagen"
  fi
  if ! sudo update-locale LANG=en_US.UTF-8 LC_MESSAGES=POSIX 2>> "$LOG_FILE"; then
    print_warning "update-locale fehlgeschlagen"
  fi
  print_success "Locale: en_US.UTF-8 / de_DE.UTF-8"
}

#-------------------------------------------------------------------------------
# /etc/wsl.conf
#-------------------------------------------------------------------------------
setup_wsl_conf() {
  print_step "/etc/wsl.conf konfigurieren..."
  if [[ "$DRY_RUN" == true ]]; then print_dim "[DRY-RUN] /etc/wsl.conf erstellen (systemd=true)"; return; fi
  [[ -f "$WSL_CONF_FILE" ]] && sudo cp "$WSL_CONF_FILE" "${WSL_CONF_FILE}.bak" \
    && print_dim "Backup: ${WSL_CONF_FILE}.bak"
  sudo tee "$WSL_CONF_FILE" > /dev/null <<'EOF'
[boot]
systemd=true

[network]
generateResolvConf=true

[interop]
appendWindowsPath=false
EOF
  print_success "/etc/wsl.conf erstellt (systemd=true, appendWindowsPath=false)"
}

#-------------------------------------------------------------------------------
# Sysctl / Kernel-Parameter
#-------------------------------------------------------------------------------
setup_sysctl() {
  print_step "Kernel-Parameter optimieren..."
  if [[ "$DRY_RUN" == true ]]; then print_dim "[DRY-RUN] vm.swappiness=10, vm.vfs_cache_pressure=50"; return; fi
  local conf='/etc/sysctl.d/99-wsl.conf'
  sudo tee "$conf" > /dev/null <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
  sudo sysctl -p "$conf" 2>> "$LOG_FILE" || print_warning "sysctl: Parameter konnten nicht live geladen werden (erst nach WSL-Neustart aktiv)"
  print_success "Kernel-Parameter gesetzt (vm.swappiness=10)"
}

#-------------------------------------------------------------------------------
# Git
#-------------------------------------------------------------------------------
setup_git() {
  print_step "Git konfigurieren..."
  if [[ "$DRY_RUN" == true ]]; then print_dim "[DRY-RUN] git config --global ..."; return; fi

  git config --global init.defaultBranch main
  git config --global core.autocrlf false
  git config --global core.eol lf
  git config --global pull.rebase false
  git config --global push.autoSetupRemote true
  git config --global rerere.enabled true
  git config --global diff.colorMoved zebra

  # Git Credential Manager (Windows-seitig, falls verfuegbar)
  local gcm
  gcm=$(command -v git-credential-manager.exe 2>/dev/null || true)
  if [[ -n "$gcm" ]]; then
    git config --global credential.helper "$gcm"
  fi

  [[ -n "${GIT_USER_NAME:-}" ]]  && git config --global user.name  "$GIT_USER_NAME"
  [[ -n "${GIT_USER_EMAIL:-}" ]] && git config --global user.email "$GIT_USER_EMAIL"

  print_success "Git konfiguriert (main-Branch, LF, rebase=false, rerere)"
}

#-------------------------------------------------------------------------------
# Shell (.bashrc)
#-------------------------------------------------------------------------------
setup_shell() {
  print_step "Shell optimieren (.bashrc)..."
  if [[ "$DRY_RUN" == true ]]; then print_dim "[DRY-RUN] .bashrc: History, Aliases, PATH"; return; fi

  # History
  # shellcheck disable=SC2016
  append_if_missing "$BASHRC_PATH" "# wsl-setup:history" \
'# wsl-setup:history
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth:erasedups
shopt -s histappend
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+;$PROMPT_COMMAND}"'

  # Aliases (ggf. von eza ueberschrieben falls im Full-Modus installiert)
  append_if_missing "$BASHRC_PATH" "# wsl-setup:aliases" \
'# wsl-setup:aliases
alias ll="ls -alFh --color=auto"
alias la="ls -Ah --color=auto"
alias l="ls -CFh --color=auto"
alias grep="grep --color=auto"
alias ..="cd .."
alias ...="cd ../.."
alias mkdir="mkdir -pv"'

  # PATH fuer ~/.local/bin
  # shellcheck disable=SC2016
  append_if_missing "$BASHRC_PATH" "# wsl-setup:path" \
'# wsl-setup:path
export PATH="$HOME/.local/bin:$PATH"'

  print_success ".bashrc optimiert"
}

#-------------------------------------------------------------------------------
# Readline (~/.inputrc)
#-------------------------------------------------------------------------------
setup_inputrc() {
  print_step "Readline konfigurieren (~/.inputrc)..."
  if [[ "$DRY_RUN" == true ]]; then print_dim "[DRY-RUN] ~/.inputrc erstellen"; return; fi
  if [[ -f "$HOME/.inputrc" ]]; then
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    cp "$HOME/.inputrc" "$HOME/.inputrc.${ts}.bak"
    print_dim "Backup: ~/.inputrc.${ts}.bak"
  fi
  cat > "$HOME/.inputrc" <<'EOF'
# History-Suche mit Pfeiltasten
"\e[A": history-search-backward
"\e[B": history-search-forward

# Tab-Completion-Verbesserungen
set completion-ignore-case on
set show-all-if-ambiguous on
set colored-stats on
set mark-symlinked-directories on
EOF
  print_success "$HOME/.inputrc erstellt"
}

#-------------------------------------------------------------------------------
# SSH
#-------------------------------------------------------------------------------
setup_ssh() {
  print_step "SSH einrichten..."
  if [[ "$DRY_RUN" == true ]]; then print_dim "[DRY-RUN] ~/.ssh/ + ~/.ssh/config erstellen"; return; fi

  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"

  if [[ ! -f "$SSH_CONFIG" ]]; then
    cat > "$SSH_CONFIG" <<'EOF'
Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    AddKeysToAgent yes

Host github.com
    User git
    IdentityFile ~/.ssh/id_ed25519

Host gitlab.com
    User git
    IdentityFile ~/.ssh/id_ed25519
EOF
    chmod 600 "$SSH_CONFIG"
  fi

  print_success "SSH konfiguriert"
}

#-------------------------------------------------------------------------------
# SSH-Key-Generierung
#-------------------------------------------------------------------------------
generate_ssh_key_if_missing() {
  [[ "$DRY_RUN" == true ]] && { print_dim "[DRY-RUN] SSH-Key-Generierung (interaktiv, falls keiner vorhanden)"; return; }
  [[ -f "$SSH_KEY" ]] && return 0
  [[ ! -t 0 ]] && return 0

  local reply
  read -r -p "  SSH-Key generieren? [J/n]: " reply
  reply="${reply:-j}"
  [[ "${reply,,}" != "j" && "${reply,,}" != "y" ]] && return 0

  local email="${SSH_KEY_EMAIL:-${GIT_USER_EMAIL:-}}"
  print_step "SSH-Key generieren... (Enter = keine Passphrase)"
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  ssh-keygen -t ed25519 -C "${email:-$(whoami)@$(hostname)}" -f "$SSH_KEY"
  print_success "SSH-Key erstellt: $SSH_KEY"
  printf '\n  %bPublic Key (fuer GitHub/GitLab → Settings → SSH Keys einfuegen):%b\n' "$CYAN" "$NC"
  if [[ -f "${SSH_KEY}.pub" ]]; then
    printf '  %s\n\n' "$(cat "${SSH_KEY}.pub")"
  fi
}

#-------------------------------------------------------------------------------
# CLI-Tools (Full-Mode)
#-------------------------------------------------------------------------------
install_cli_tools() {
  print_step "CLI-Tools installieren..."

  if [[ "$DRY_RUN" == true ]]; then
    print_dim "[DRY-RUN] apt: ripgrep, fd-find, bat, fzf, tmux, ncdu, direnv, git-delta"
    print_dim "[DRY-RUN] eza (GitHub Releases), zoxide, gh (GitHub CLI)"
    print_dim "[DRY-RUN] pwsh (Microsoft apt-Repo)"
    print_dim "[DRY-RUN] yq, lazygit (GitHub Releases)"
    return
  fi

  local -a apt_tools=(ripgrep fd-find bat fzf tmux ncdu direnv git-delta)
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${apt_tools[@]}" 2>> "$LOG_FILE"; then
    print_warning "Einige CLI-Pakete nicht installiert – Details: $LOG_FILE"
  fi

  # delta als git-Pager konfigurieren
  if command -v delta &>/dev/null; then
    git config --global core.pager delta
    git config --global interactive.diffFilter 'delta --color-only'
    git config --global delta.navigate true
    print_success "delta als git-Pager konfiguriert"
  fi

  mkdir -p "$LOCAL_BIN_DIR"

  # Ubuntu-spezifische Binarnamen mit Symlinks korrigieren
  ensure_user_symlink batcat bat
  ensure_user_symlink fdfind fd

  _install_eza
  _install_zoxide
  _install_gh_cli
  _install_pwsh
  _install_yq
  _install_lazygit

  print_success "CLI-Tools installiert"
}

_install_eza() {
  command -v eza &>/dev/null && { print_success "eza bereits vorhanden"; return; }
  local tmp; tmp=$(mktemp -d)
  local arch; arch=$(uname -m)
  case "$arch" in
    x86_64|aarch64) ;;
    *) print_warning "eza: Nicht unterstuetzte Architektur: $arch – uebersprungen"; return ;;
  esac
  local url="https://github.com/eza-community/eza/releases/latest/download/eza_${arch}-unknown-linux-gnu.tar.gz"
  if curl -fsSL --connect-timeout 30 --max-time 300 "$url" -o "$tmp/eza.tar.gz" 2>> "$LOG_FILE"; then
    if tar xzf "$tmp/eza.tar.gz" -C "$tmp" 2>> "$LOG_FILE" \
        && install -m 755 "$tmp/eza" "$LOCAL_BIN_DIR/eza"; then
      print_success "eza installiert"
      # ls-Aliases auf eza umstellen
      append_if_missing "$BASHRC_PATH" "# wsl-setup:eza" \
'# wsl-setup:eza
alias ls="eza --color=auto --group-directories-first"
alias ll="eza -alFh --git --group-directories-first"
alias la="eza -ah --group-directories-first"
alias lt="eza --tree --level=2"'
    else
      print_warning "eza: Entpacken fehlgeschlagen – uebersprungen"
    fi
  else
    print_warning "eza: Download fehlgeschlagen – uebersprungen"
  fi
  rm -rf "$tmp"
}

_install_zoxide() {
  command -v zoxide &>/dev/null && { print_success "zoxide bereits vorhanden"; return; }
  local tmp; tmp=$(mktemp)
  if curl -fsSL --connect-timeout 30 --max-time 120 \
      https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \
      -o "$tmp" 2>> "$LOG_FILE" \
      && _validate_installer_script "$tmp" "zoxide" \
      && bash "$tmp" 2>> "$LOG_FILE"; then
    # shellcheck disable=SC2016
    append_if_missing "$BASHRC_PATH" "# wsl-setup:zoxide" \
'# wsl-setup:zoxide
eval "$(zoxide init bash)"'
    print_success "zoxide installiert"
  else
    print_warning "zoxide: Installation fehlgeschlagen – uebersprungen"
  fi
  rm -f "$tmp"
}

_install_gh_cli() {
  command -v gh &>/dev/null && { print_success "gh bereits vorhanden"; return; }
  local keyring='/etc/apt/keyrings/githubcli-archive-keyring.gpg'
  local gpg_tmp; gpg_tmp=$(mktemp)
  if curl -fsSL --connect-timeout 30 --max-time 60 \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o "$gpg_tmp" 2>> "$LOG_FILE" \
    && sudo install -m 644 "$gpg_tmp" "$keyring" \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] \
https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && sudo apt-get update -qq 2>> "$LOG_FILE" \
    && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh 2>> "$LOG_FILE"; then
    print_success "gh (GitHub CLI) installiert"
  else
    print_warning "gh: Installation fehlgeschlagen – uebersprungen"
  fi
  rm -f "$gpg_tmp"
}

_install_pwsh() {
  command -v pwsh &>/dev/null && { print_success "pwsh bereits vorhanden"; return; }
  local ubuntu_version
  ubuntu_version=$(lsb_release -rs 2>> "$LOG_FILE")
  if [[ -z "$ubuntu_version" ]]; then
    print_warning "pwsh: Ubuntu-Version nicht ermittelbar – uebersprungen"
    return
  fi
  local tmp_deb
  tmp_deb=$(mktemp --suffix=.deb)
  local deb_url="https://packages.microsoft.com/config/ubuntu/${ubuntu_version}/packages-microsoft-prod.deb"
  if curl -fsSL --connect-timeout 30 --max-time 120 "$deb_url" -o "$tmp_deb" 2>> "$LOG_FILE" \
    && sudo dpkg -i "$tmp_deb" 2>> "$LOG_FILE" \
    && sudo apt-get update -qq 2>> "$LOG_FILE" \
    && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq powershell 2>> "$LOG_FILE"; then
    print_success "pwsh $(pwsh --version 2>/dev/null | cut -d' ' -f2 || echo '?') installiert"
  else
    print_warning "pwsh: Installation fehlgeschlagen – uebersprungen"
  fi
  rm -f "$tmp_deb"
}

_install_yq() {
  command -v yq &>/dev/null && { print_success "yq bereits vorhanden"; return; }
  local arch; arch=$(dpkg --print-architecture)
  local url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"
  local tmp; tmp=$(mktemp)
  if curl -fsSL --connect-timeout 30 --max-time 300 "$url" -o "$tmp" 2>> "$LOG_FILE" \
    && install -m 755 "$tmp" "$LOCAL_BIN_DIR/yq"; then
    print_success "yq $("$LOCAL_BIN_DIR/yq" --version 2>/dev/null | awk '{print $NF}' || echo '?') installiert"
  else
    print_warning "yq: Download fehlgeschlagen – uebersprungen"
  fi
  rm -f "$tmp"
}

_install_lazygit() {
  command -v lazygit &>/dev/null && { print_success "lazygit bereits vorhanden"; return; }
  local version
  version=$(curl -fsSL --connect-timeout 30 --max-time 60 \
    "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" 2>> "$LOG_FILE" \
    | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^v//' || true)
  if [[ -z "$version" ]] || ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print_warning "lazygit: Version nicht ermittelbar – uebersprungen"
    return
  fi
  local tmp; tmp=$(mktemp -d)
  local arch; arch=$(uname -m)
  # lazygit nutzt "arm64" statt "aarch64" fuer ARM-Releases
  [[ "$arch" == "aarch64" ]] && arch="arm64"
  local url="https://github.com/jesseduffield/lazygit/releases/download/v${version}/lazygit_${version}_Linux_${arch}.tar.gz"
  if curl -fsSL --connect-timeout 30 --max-time 300 "$url" -o "$tmp/lazygit.tar.gz" 2>> "$LOG_FILE"; then
    if tar xzf "$tmp/lazygit.tar.gz" -C "$tmp" lazygit 2>> "$LOG_FILE" \
        && install -m 755 "$tmp/lazygit" "$LOCAL_BIN_DIR/lazygit"; then
      print_success "lazygit ${version} installiert"
    else
      print_warning "lazygit: Entpacken fehlgeschlagen – uebersprungen"
    fi
  else
    print_warning "lazygit: Download fehlgeschlagen – uebersprungen"
  fi
  rm -rf "$tmp"
}

#-------------------------------------------------------------------------------
# Browser-Integration
#-------------------------------------------------------------------------------
install_browser_integration() {
  print_step "Browser-Integration installieren (xdg-utils, wslu)..."
  if [[ "$DRY_RUN" == true ]]; then print_dim "[DRY-RUN] apt install xdg-utils wslu"; return; fi
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xdg-utils wslu 2>> "$LOG_FILE"; then
    print_success "Browser-Integration bereit (wslview)"
  else
    print_warning "wslu nicht verfuegbar – uebersprungen"
  fi
}

#-------------------------------------------------------------------------------
# Dev-Dependencies
#-------------------------------------------------------------------------------
install_dev_dependencies() {
  print_step "Dev-Dependencies installieren..."
  local -a packages=(
    # Compiler & Debugger
    gcc g++ gdb clang clang-format clang-tidy lldb
    # Build
    cmake make ninja-build
    # Datenbank
    sqlite3 postgresql-client
    # Tools
    jq tree file htop shellcheck
  )
  if [[ "$DRY_RUN" == true ]]; then
    print_dim "[DRY-RUN] apt install: ${packages[*]}"
    return
  fi
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" 2>> "$LOG_FILE"; then
    print_success "Dev-Dependencies installiert"
  else
    print_warning "Einige Dev-Pakete konnten nicht installiert werden – Details: $LOG_FILE"
  fi
}

#-------------------------------------------------------------------------------
# Python + uv
#-------------------------------------------------------------------------------
setup_python() {
  print_step "Python + uv installieren..."
  if [[ "$DRY_RUN" == true ]]; then print_dim "[DRY-RUN] python3, pip, venv + uv (astral.sh)"; return; fi

  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      python3 python3-pip python3-venv python3-dev 2>> "$LOG_FILE"; then
    print_warning "Python-Pakete: Installation fehlgeschlagen – uebersprungen"
    return
  fi

  if ! command -v uv &>/dev/null; then
    local uv_tmp; uv_tmp=$(mktemp)
    if curl -fsSL --connect-timeout 30 --max-time 120 https://astral.sh/uv/install.sh \
        -o "$uv_tmp" 2>> "$LOG_FILE" \
        && _validate_installer_script "$uv_tmp" "uv" \
        && bash "$uv_tmp" 2>> "$LOG_FILE"; then
      print_success "uv installiert"
    else
      print_warning "uv: Installation fehlgeschlagen – uebersprungen"
    fi
    rm -f "$uv_tmp"
  fi

  # pip-Konfiguration: kein break-system-packages noetig
  mkdir -p "$HOME/.config/pip"
  cat > "$HOME/.config/pip/pip.conf" <<'EOF'
[global]
break-system-packages = false
EOF

  local py_version
  py_version=$(python3 --version 2>/dev/null | cut -d' ' -f2 || echo "?")
  local uv_info=""
  command -v uv &>/dev/null && uv_info=" + uv"
  print_success "Python $py_version$uv_info"
}

#-------------------------------------------------------------------------------
# Node.js via nvm
#-------------------------------------------------------------------------------
setup_nodejs() {
  print_step "Node.js (nvm $NVM_VERSION) installieren..."
  if [[ "$DRY_RUN" == true ]]; then
    print_dim "[DRY-RUN] nvm ${NVM_VERSION} + Node.js ${NODE_VERSION} + pnpm"
    return
  fi

  local nvm_dir="$HOME/.nvm"

  if [[ ! -s "$nvm_dir/nvm.sh" ]]; then
    local nvm_tmp; nvm_tmp=$(mktemp)
    if curl -fsSL --connect-timeout 30 --max-time 120 \
        "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" \
        -o "$nvm_tmp" 2>> "$LOG_FILE" \
        && _validate_installer_script "$nvm_tmp" "nvm" \
        && bash "$nvm_tmp" 2>> "$LOG_FILE"; then
      print_success "nvm ${NVM_VERSION} installiert"
    else
      rm -f "$nvm_tmp"
      print_warning "nvm: Installation fehlgeschlagen – uebersprungen"
      return
    fi
    rm -f "$nvm_tmp"
  fi

  export NVM_DIR="$nvm_dir"
  # shellcheck source=/dev/null
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

  if ! nvm install "$NODE_VERSION" 2>> "$LOG_FILE"; then
    print_warning "nvm install fehlgeschlagen – uebersprungen"
    return
  fi
  if ! nvm use "$NODE_VERSION" 2>> "$LOG_FILE"; then
    print_warning "nvm use fehlgeschlagen"
  fi
  if ! nvm alias default "$NODE_VERSION" 2>> "$LOG_FILE"; then
    print_warning "nvm alias default fehlgeschlagen"
  fi

  if ! command -v pnpm &>/dev/null; then
    if npm install -g pnpm 2>> "$LOG_FILE"; then
      print_success "pnpm installiert"
    else
      print_warning "pnpm: Installation fehlgeschlagen"
    fi
  fi

  local node_ver
  node_ver=$(node --version 2>/dev/null || true)
  if [[ -n "$node_ver" ]]; then
    print_success "Node.js $node_ver + pnpm"
  else
    print_warning "Node.js: Version nicht ermittelbar"
  fi
}

#-------------------------------------------------------------------------------
# tmux-Konfiguration
#-------------------------------------------------------------------------------
setup_tmux() {
  print_step "tmux konfigurieren (~/.tmux.conf)..."
  if [[ "$DRY_RUN" == true ]]; then print_dim "[DRY-RUN] ~/.tmux.conf erstellen"; return; fi
  if [[ -f "$HOME/.tmux.conf" ]]; then
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    cp "$HOME/.tmux.conf" "$HOME/.tmux.conf.${ts}.bak"
    print_dim "Backup: ~/.tmux.conf.${ts}.bak"
  fi

  cat > "$HOME/.tmux.conf" <<'EOF'
# Prefix: Ctrl+a (wie GNU screen)
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# Fenster-Splitting
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# Pane-Navigation (Vi-Style)
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Vi-Modus
setw -g mode-keys vi
bind-key -T copy-mode-vi v send-keys -X begin-selection
bind-key -T copy-mode-vi y send-keys -X copy-selection-and-cancel

# Mouse
set -g mouse on

# Farben & Terminal
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:Tc"

# Fenster-Nummerierung ab 1
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# Kein Delay nach Escape
set -s escape-time 10

# Laengeren History-Puffer
set -g history-limit 10000

# Status-Bar
set -g status-style 'bg=#1e1e2e fg=#cdd6f4'
set -g status-left-length 30
set -g status-right "#[fg=#a6e3a1]%H:%M  #[fg=#89b4fa]%d.%m.%Y"
set -g window-status-current-style 'fg=#1e1e2e bg=#89b4fa bold'

# Config neu laden
bind r source-file ~/.tmux.conf \; display "~/.tmux.conf neu geladen"
EOF
  print_success "$HOME/.tmux.conf erstellt"
}

#-------------------------------------------------------------------------------
# zsh + Oh-My-Zsh
#-------------------------------------------------------------------------------
setup_zsh() {
  print_step "zsh + Oh-My-Zsh + Plugins einrichten..."
  if [[ "$DRY_RUN" == true ]]; then
    print_dim "[DRY-RUN] zsh, Oh-My-Zsh, zsh-autosuggestions, zsh-syntax-highlighting, .zshrc, chsh"
    return
  fi

  # zsh installieren
  if ! command -v zsh &>/dev/null; then
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zsh 2>> "$LOG_FILE"; then
      print_warning "zsh: Installation fehlgeschlagen – uebersprungen"
      return
    fi
  fi

  # Oh-My-Zsh installieren (falls noch nicht vorhanden)
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    local omz_tmp
    omz_tmp=$(mktemp)
    if curl -fsSL --connect-timeout 30 --max-time 120 \
        https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh \
        -o "$omz_tmp" 2>> "$LOG_FILE" \
        && _validate_installer_script "$omz_tmp" "Oh-My-Zsh"; then
      RUNZSH=no CHSH=no bash "$omz_tmp" 2>> "$LOG_FILE" \
        || print_warning "Oh-My-Zsh: Installation fehlgeschlagen"
    else
      print_warning "Oh-My-Zsh: Download fehlgeschlagen – uebersprungen"
    fi
    rm -f "$omz_tmp"
  fi

  # Plugins klonen
  local zsh_custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  if [[ ! -d "$zsh_custom/plugins/zsh-autosuggestions" ]]; then
    GIT_TERMINAL_PROMPT=0 git clone --depth=1 \
      https://github.com/zsh-users/zsh-autosuggestions \
      "$zsh_custom/plugins/zsh-autosuggestions" 2>> "$LOG_FILE" \
      || print_warning "zsh-autosuggestions: Klonen fehlgeschlagen"
  fi
  if [[ ! -d "$zsh_custom/plugins/zsh-syntax-highlighting" ]]; then
    GIT_TERMINAL_PROMPT=0 git clone --depth=1 \
      https://github.com/zsh-users/zsh-syntax-highlighting \
      "$zsh_custom/plugins/zsh-syntax-highlighting" 2>> "$LOG_FILE" \
      || print_warning "zsh-syntax-highlighting: Klonen fehlgeschlagen"
  fi

  # .zshrc konfigurieren
  local zshrc="$HOME/.zshrc"
  if [[ -f "$zshrc" ]]; then
    # Plugins aktivieren (idempotent via Grep-Check)
    if ! grep -qF "zsh-autosuggestions" "$zshrc"; then
      sed -i -E '0,/^plugins=\(.*\)/{s/^plugins=\(.*\)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/}' "$zshrc"
    fi
    # ~/.local/bin in PATH
    # shellcheck disable=SC2016
    append_if_missing "$zshrc" "# wsl-setup:zsh-path" \
'# wsl-setup:zsh-path
export PATH="$HOME/.local/bin:$PATH"'
    # nvm einbinden (falls installiert)
    if [[ -d "$HOME/.nvm" ]]; then
      # shellcheck disable=SC2016
      append_if_missing "$zshrc" "# wsl-setup:nvm-zsh" \
'# wsl-setup:nvm-zsh
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
    fi
  fi

  # Als Default-Shell setzen
  local zsh_bin; zsh_bin=$(command -v zsh 2>/dev/null || true)
  if [[ -z "$zsh_bin" ]]; then
    print_warning "zsh nicht im PATH – Shell-Wechsel uebersprungen"
    return
  fi
  local current_shell; current_shell=$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || echo "")
  if [[ "$current_shell" != "$zsh_bin" ]]; then
    sudo chsh -s "$zsh_bin" "$USER" 2>> "$LOG_FILE" \
      || print_warning "chsh fehlgeschlagen – Shell manuell aendern: chsh -s $zsh_bin"
  fi

  local zsh_ver; zsh_ver=$(zsh --version 2>/dev/null | cut -d' ' -f2 || echo "?")
  print_success "zsh $zsh_ver + Oh-My-Zsh + Plugins eingerichtet"
}

#-------------------------------------------------------------------------------
# Error Handler
#-------------------------------------------------------------------------------
SUDO_KEEPALIVE_PID=""

cleanup() {
  local exit_code=$?
  # Kill sudo keepalive if running
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
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
    print_error "Nicht als root ausfuehren! Normalen User verwenden."
    exit 1
  fi

  if ! grep -qi microsoft /proc/version 2>/dev/null; then
    print_warning "Nicht in WSL2 erkannt – einige Features koennen fehlen"
  fi

  local -a required_cmds=(sudo apt-get curl git)
  local cmd
  for cmd in "${required_cmds[@]}"; do
    command -v "$cmd" &>/dev/null || { print_error "Benoetigt: $cmd"; exit 1; }
  done

  if ! sudo -n true 2>/dev/null; then
    [[ "$DRY_RUN" == true ]] && return
    print_step "Sudo-Berechtigung pruefen..."
    sudo -v
  fi
}

collect_identity_inputs() {
  [[ "$DRY_RUN" == true ]] && return
  [[ ! -t 0 ]] && return

  print_step "Benutzerdaten (optional – Enter zum Ueberspringen)"

  if [[ -z "$GIT_USER_NAME" ]]; then
    read -r -p "  Git Benutzername: " GIT_USER_NAME
  fi

  if [[ -z "$GIT_USER_EMAIL" ]]; then
    while true; do
      read -r -p "  Git E-Mail: " GIT_USER_EMAIL
      is_valid_email "$GIT_USER_EMAIL" && break
      [[ -z "$GIT_USER_EMAIL" ]] && break
      print_warning "Ungueltige E-Mail-Adresse. Erneut versuchen."
    done
  fi

  if [[ -z "$SSH_KEY_EMAIL" ]]; then
    while true; do
      local prompt="  SSH-Key E-Mail"
      [[ -n "$GIT_USER_EMAIL" ]] && prompt="  SSH-Key E-Mail (Enter = $GIT_USER_EMAIL)"
      read -r -p "$prompt: " SSH_KEY_EMAIL
      [[ -z "$SSH_KEY_EMAIL" && -n "$GIT_USER_EMAIL" ]] && SSH_KEY_EMAIL="$GIT_USER_EMAIL"
      is_valid_email "$SSH_KEY_EMAIL" && break
      [[ -z "$SSH_KEY_EMAIL" ]] && break
      print_warning "Ungueltige E-Mail-Adresse. Erneut versuchen."
      SSH_KEY_EMAIL=""
    done
  fi
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
  cat <<'EOF'
Ubuntu WSL2 Setup – Optimierte Entwicklungsumgebung

VERWENDUNG:
  ./ubuntu-wsl-setup.sh [OPTIONEN]

OPTIONEN:
  --minimal            Basis-System + Git + Shell + SSH
  --full               Alles installieren (Standard)
  --dry-run            Geplante Schritte anzeigen ohne Ausfuehrung
  --git-user-name N    Git user.name vorbelegen
  --git-user-email E   Git user.email vorbelegen
  --ssh-key-email E    E-Mail fuer SSH-Key vorbelegen
  --help, -h           Diese Hilfe

MINIMAL installiert:
  System-Update, Basis-Pakete, Locale, /etc/wsl.conf, Kernel-Parameter,
  Git, Shell (.bashrc), Readline (.inputrc), SSH

FULL installiert zusaetzlich:
  CLI-Tools: ripgrep, fd, bat, fzf, tmux, ncdu, eza, zoxide, gh, direnv
  Browser-Integration: xdg-utils, wslu (wslview)
  Dev-Dependencies: gcc, clang, cmake, sqlite3, postgresql-client, jq, shellcheck
  Python 3 + uv (astral.sh)
  Node.js LTS (via nvm) + pnpm
  tmux-Konfiguration (~/.tmux.conf)

AM ENDE (interaktiv, wenn TTY vorhanden):
  GitHub CLI authentifizieren  (gh auth login)
  Passwordless sudo einrichten (sudo ohne Passwort – /etc/sudoers.d/USER-nopasswd)
EOF
}

#-------------------------------------------------------------------------------
# Banner
#-------------------------------------------------------------------------------
show_banner() {
  printf '%b' "$CYAN"
  cat <<'EOF'
  _   _ _                 _          ____       _
 | | | | |__  _   _ _ __ | |_ _   _ / ___|  ___| |_ _   _ _ __
 | | | | '_ \| | | | '_ \| __| | | | \___ \ / _ \ __| | | | '_ \
 | |_| | |_) | |_| | | | | |_| |_| |  ___) |  __/ |_| |_| | |_) |
  \___/|_.__/ \__,_|_| |_|\__|\__,_| |____/ \___|\__|\__,_| .__/
                                                           |_|
EOF
  printf '%b\n' "$NC"
  printf '%b  Mode: %s | Log: %s%b\n' "$DIM" "$INSTALL_MODE" "$LOG_FILE" "$NC"
  if [[ "$DRY_RUN" == true ]]; then
    printf '%b  [DRY-RUN] Keine Aenderungen werden durchgefuehrt%b\n' "$YELLOW" "$NC"
  fi
  printf '\n'
}

#-------------------------------------------------------------------------------
# Dry-Run Plan
#-------------------------------------------------------------------------------
show_dry_run_plan() {
  print_step "Geplante Schritte (Dry-Run):"
  echo ""
  echo "  Immer ($INSTALL_MODE):"
  echo "    1. System aktualisieren (apt-get update + full-upgrade)"
  echo "    2. Basis-Pakete installieren (curl, wget, git, gnupg2, build-essential, ...)"
  echo "    3. Locale konfigurieren (en_US.UTF-8, de_DE.UTF-8)"
  echo "    4. /etc/wsl.conf erstellen (systemd=true, appendWindowsPath=false)"
  echo "    5. Kernel-Parameter optimieren (vm.swappiness=10)"
  echo "    6. Git konfigurieren (main-Branch, LF, rebase=false, rerere)"
  echo "    7. Shell optimieren (.bashrc – History, Aliases, PATH)"
  echo "    8. Readline konfigurieren (~/.inputrc)"
  echo "    9. SSH einrichten (~/.ssh/config)"

  if [[ "$INSTALL_MODE" == "$MODE_FULL" ]]; then
    echo ""
    echo "  Full-Mode zusaetzlich:"
    echo "   10. CLI-Tools (ripgrep, fd, bat, fzf, tmux, ncdu, direnv, git-delta)"
    echo "   11. eza (modernes ls, via GitHub Releases)"
    echo "   12. zoxide (smarter cd)"
    echo "   13. gh (GitHub CLI, via apt)"
    echo "   14. Browser-Integration (xdg-utils, wslu)"
    echo "   15. Dev-Dependencies (gcc, clang, cmake, sqlite3, jq, shellcheck, ...)"
    echo "   16. Python 3 + uv (via astral.sh)"
    echo "   17. Node.js LTS (via nvm ${NVM_VERSION}) + pnpm"
    echo "   18. tmux-Konfiguration (~/.tmux.conf)"
    echo "   19. pwsh (PowerShell Core, via Microsoft apt-Repo)"
    echo "   20. yq, lazygit (via GitHub Releases)"
    echo "   21. zsh + Oh-My-Zsh + Plugins (zsh-autosuggestions, zsh-syntax-highlighting)"
  fi

  echo ""
  echo "  Interaktiv am Ende (nur wenn TTY vorhanden):"
  echo "    - GitHub CLI authentifizieren (gh auth login)"
  echo "    - Passwordless sudo anbieten (/etc/sudoers.d/${USER}-nopasswd)"
  echo ""
  print_dim "Zum Ausfuehren Script ohne --dry-run starten"
}

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
show_summary() {
  local py_version=""
  py_version=$(python3 --version 2>/dev/null | cut -d' ' -f2 || echo "nicht installiert")

  printf '\n%b' "$GREEN"
  cat <<'EOF'
===============================================================================
                         Setup abgeschlossen!
===============================================================================
EOF
  printf '%b\n' "$NC"

  printf '  Installiert:\n'
  printf '    %b+%b System-Update, Basis-Pakete, Locale, WSL-Config, Kernel-Parameter\n' "$GREEN" "$NC"
  printf '    %b+%b Git, Shell (.bashrc), Readline (.inputrc), SSH\n' "$GREEN" "$NC"

  command -v python3 &>/dev/null && \
    printf '    %b+%b Python %s + uv\n' "$GREEN" "$NC" "$py_version"

  if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    local node_ver=""
    # shellcheck source=/dev/null
    node_ver=$(source "$HOME/.nvm/nvm.sh" && node --version 2>/dev/null || echo "")
    [[ -n "$node_ver" ]] && printf '    %b+%b Node.js %s + pnpm\n' "$GREEN" "$NC" "$node_ver"
  fi

  if [[ "$INSTALL_MODE" == "$MODE_FULL" ]]; then
    printf '    %b+%b CLI-Tools (ripgrep, fd, bat, eza, zoxide, fzf, gh, git-delta, direnv, pwsh, yq, lazygit)\n' "$GREEN" "$NC"
    printf '    %b+%b Dev-Dependencies, Browser-Integration, tmux\n' "$GREEN" "$NC"
    [[ -d "$HOME/.oh-my-zsh" ]] && \
      printf '    %b+%b zsh + Oh-My-Zsh (zsh-autosuggestions, zsh-syntax-highlighting)\n' "$GREEN" "$NC"
  fi

  printf '\n  Naechste Schritte:\n\n'
  printf '  1. WSL neu starten (in Windows PowerShell ausfuehren):\n'
  printf '     %bwsl --shutdown%b\n\n' "$CYAN" "$NC"

  if [[ -n "${GIT_USER_NAME:-}" || -n "${GIT_USER_EMAIL:-}" ]]; then
    printf '  2. Git-Konfiguration gesetzt:\n'
    [[ -n "${GIT_USER_NAME:-}" ]]  && printf '     Name:   %b%s%b\n' "$CYAN" "$GIT_USER_NAME" "$NC"
    [[ -n "${GIT_USER_EMAIL:-}" ]] && printf '     E-Mail: %b%s%b\n\n' "$CYAN" "$GIT_USER_EMAIL" "$NC"
  else
    printf '  2. Git-Benutzer setzen (optional):\n'
    printf '     %bgit config --global user.name "Dein Name"%b\n' "$CYAN" "$NC"
    printf '     %bgit config --global user.email "deine@email.com"%b\n\n' "$CYAN" "$NC"
  fi

  if [[ -f "$SSH_KEY" ]]; then
    printf '  3. SSH-Key vorhanden: %b%s.pub%b\n\n' "$CYAN" "$SSH_KEY" "$NC"
  else
    local ssh_email="${SSH_KEY_EMAIL:-${GIT_USER_EMAIL:-deine@email.com}}"
    printf '  3. SSH-Key generieren (optional):\n'
    printf '     %bssh-keygen -t ed25519 -C "%s"%b\n\n' "$CYAN" "$ssh_email" "$NC"
  fi

  printf '  Log: %b%s%b\n\n' "$DIM" "$LOG_FILE" "$NC"
  printf '===============================================================================\n\n'
}

#-------------------------------------------------------------------------------
# GitHub CLI Auth
#-------------------------------------------------------------------------------
offer_gh_auth_login() {
  command -v gh &>/dev/null || return 0
  gh auth status >> "$LOG_FILE" 2>&1 && return 0
  [[ ! -t 0 ]] && return 0

  local reply
  read -r -p "  GitHub CLI authentifizieren? (gh auth login) [J/n]: " reply
  reply="${reply:-j}"
  [[ "${reply,,}" != "j" && "${reply,,}" != "y" ]] && return 0

  gh auth login
}

offer_passwordless_sudo() {
  local sudoers_file="/etc/sudoers.d/${USER}-nopasswd"
  [[ -f "$sudoers_file" ]] && return 0
  if [[ "$DRY_RUN" == true ]]; then
    print_dim "[DRY-RUN] Passwordless sudo anbieten (Datei: $sudoers_file)"
    return 0
  fi
  [[ ! -t 0 ]] && return 0

  print_step "Passwordless sudo (optional)"
  print_dim "Erlaubt 'sudo' ohne Passwort-Eingabe (nuetzlich fuer CI, Claude Code, Skripte)"

  local reply
  read -r -p "  Passwordless sudo einrichten? [j/N]: " reply
  [[ "${reply,,}" != "j" && "${reply,,}" != "y" ]] && return 0

  # Validate username before writing sudoers rule
  if [[ ! "$USER" =~ ^[a-z_][a-z0-9_.-]*$ ]]; then
    print_error "Ungueltiger Benutzername fuer sudoers: $USER"
    return 1
  fi

  local tmp_sudoers
  tmp_sudoers=$(mktemp)
  echo "${USER} ALL=(ALL) NOPASSWD: ALL" > "$tmp_sudoers"

  # Validate sudoers syntax before installing
  if ! sudo visudo -c -f "$tmp_sudoers" > /dev/null 2>&1; then
    print_error "Sudoers-Syntax ungueltig"
    rm -f "$tmp_sudoers"
    return 1
  fi

  sudo install -m 440 "$tmp_sudoers" "$sudoers_file"
  rm -f "$tmp_sudoers"
  print_success "Passwordless sudo eingerichtet: $sudoers_file"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
  parse_args "$@"
  install -m 600 /dev/null "$LOG_FILE"
  log "=== Setup gestartet: $INSTALL_MODE ==="
  show_banner
  preflight_checks
  collect_identity_inputs
  assert_valid_email_or_exit "$GIT_USER_EMAIL" "Git E-Mail"
  assert_valid_email_or_exit "$SSH_KEY_EMAIL" "SSH-Key E-Mail"

  if [[ "$DRY_RUN" == true ]]; then
    show_dry_run_plan
    exit 0
  fi

  # sudo-Keepalive: verhindert Credential-Verfall (Standard: 15 Min) bei langem Setup
  # Terminates automatically when parent process dies (kill -0 check)
  ( while kill -0 $$ 2>/dev/null; do sleep 59; sudo -v 2>/dev/null || break; done ) &
  SUDO_KEEPALIVE_PID=$!

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
    setup_zsh
  fi

  log "=== Setup beendet ==="
  show_summary
  offer_gh_auth_login
  offer_passwordless_sudo
}

main "$@"
