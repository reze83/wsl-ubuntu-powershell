#!/bin/bash
#===============================================================================
# Ubuntu WSL2 Setup – Validierungs-Script
#
# Prueft ob ubuntu-wsl-setup.sh erfolgreich ausgefuehrt wurde.
#
# Verwendung:
#   chmod +x ubuntu-wsl-validate.sh && ./ubuntu-wsl-validate.sh
#
# Optionen:
#   --minimal    Nur Basis-Checks (ohne Full-Mode-Tools)
#   --full       Alle Checks inkl. Full-Mode-Tools (Standard)
#   --help, -h   Diese Hilfe
#
# Exit-Codes:
#   0 = Alle Checks bestanden
#   1 = Mindestens ein Check fehlgeschlagen
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Farben (ANSI, bash-kompatibel)
#-------------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

#-------------------------------------------------------------------------------
# Zaehler
#-------------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

#-------------------------------------------------------------------------------
# Hilfsfunktionen
#-------------------------------------------------------------------------------
pass() {
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf '  %b[PASS]%b %s\n' "${GREEN}" "${NC}" "$1"
}

fail() {
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf '  %b[FAIL]%b %s\n' "${RED}" "${NC}" "$1"
    if [[ -n "${2:-}" ]]; then
        printf '         %b%s%b\n' "${DIM}" "$2" "${NC}"
    fi
}

warn() {
    WARN_COUNT=$(( WARN_COUNT + 1 ))
    printf '  %b[WARN]%b %s\n' "${YELLOW}" "${NC}" "$1"
    if [[ -n "${2:-}" ]]; then
        printf '         %b%s%b\n' "${DIM}" "$2" "${NC}"
    fi
}

section() {
    printf '\n%b--- %s%b\n' "${CYAN}" "$1" "${NC}"
}

check_pkg() {
    local pkg="$1"
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        pass "Paket installiert: $pkg"
    else
        fail "Paket fehlt: $pkg" "sudo apt-get install -y $pkg"
    fi
}

check_cmd() {
    local cmd="$1"
    local label="${2:-$cmd}"
    if command -v "$cmd" &>/dev/null; then
        local loc
        loc=$(command -v "$cmd")
        pass "Befehl verfuegbar: $label ($loc)"
    else
        fail "Befehl nicht gefunden: $label" "Erwarte: $cmd im PATH"
    fi
}

check_file() {
    local path="$1"
    local label="${2:-$path}"
    if [[ -f "$path" ]]; then
        pass "Datei vorhanden: $label"
    else
        fail "Datei fehlt: $label" "Erwartet: $path"
    fi
}

check_dir() {
    local path="$1"
    local label="${2:-$path}"
    if [[ -d "$path" ]]; then
        pass "Verzeichnis vorhanden: $label"
    else
        fail "Verzeichnis fehlt: $label" "Erwartet: $path"
    fi
}

check_file_contains() {
    local path="$1"
    local marker="$2"
    local label="$3"
    if [[ -f "$path" ]] && grep -qF "$marker" "$path" 2>/dev/null; then
        pass "$label"
    else
        fail "$label" "Marker nicht gefunden: '$marker' in $path"
    fi
}

check_git_config() {
    local key="$1"
    local expected="$2"
    local actual
    actual=$(git config --global --get "$key" 2>/dev/null || true)
    if [[ "$actual" == "$expected" ]]; then
        pass "git config $key = $expected"
    else
        fail "git config $key falsch" "Erwartet: '$expected', Gefunden: '${actual:-<leer>}'"
    fi
}

#-------------------------------------------------------------------------------
# CLI Argument Parsing
#-------------------------------------------------------------------------------
MODE="--full"

show_help() {
    cat <<'EOF'
Ubuntu WSL2 Validierungs-Script

VERWENDUNG:
  ./ubuntu-wsl-validate.sh [OPTIONEN]

OPTIONEN:
  --minimal    Nur Basis-Checks (System, Git, Shell, SSH)
  --full       Alle Checks inkl. Full-Mode-Tools (Standard)
  --help, -h   Diese Hilfe

EXIT-CODES:
  0 = Alle Checks bestanden
  1 = Mindestens ein Check fehlgeschlagen
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --minimal) MODE="--minimal" ;;
            --full)    MODE="--full" ;;
            --help|-h) show_help; exit 0 ;;
            *)
                printf '%b[ERROR]%b Unbekannte Option: %s\n' "${RED}" "${NC}" "$1" >&2
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

#-------------------------------------------------------------------------------
# 1. WSL-Umgebung
#-------------------------------------------------------------------------------
check_wsl_environment() {
    section "WSL-Umgebung"

    if grep -qi microsoft /proc/version 2>/dev/null; then
        pass "WSL2-Umgebung erkannt (/proc/version)"
    else
        warn "WSL2 nicht erkannt" "Moegliche Bare-Metal-Installation oder WSL1"
    fi

    if [[ $EUID -ne 0 ]]; then
        pass "Nicht als root ausgefuehrt (korrekt)"
    else
        fail "Script laeuft als root" "Normalen Benutzer verwenden"
    fi

    if command -v sudo &>/dev/null; then
        pass "sudo verfuegbar"
    else
        fail "sudo nicht gefunden" "sudo ist fuer das Setup erforderlich"
    fi
}

#-------------------------------------------------------------------------------
# 2. Basis-Pakete
#-------------------------------------------------------------------------------
check_base_packages() {
    section "Basis-Pakete"

    local -a base_pkgs=(
        curl wget git gnupg2 ca-certificates
        apt-transport-https software-properties-common
        lsb-release locales unzip zip
        build-essential pkg-config
        openssh-client
    )

    local pkg
    for pkg in "${base_pkgs[@]}"; do
        check_pkg "$pkg"
    done
}

#-------------------------------------------------------------------------------
# 3. Locale
#-------------------------------------------------------------------------------
check_locale() {
    section "Locale-Konfiguration"

    if locale -a 2>/dev/null | grep -q 'en_US.utf8'; then
        pass "Locale en_US.UTF-8 generiert"
    else
        fail "Locale en_US.UTF-8 fehlt" "sudo locale-gen en_US.UTF-8"
    fi

    if locale -a 2>/dev/null | grep -q 'de_DE.utf8'; then
        pass "Locale de_DE.UTF-8 generiert"
    else
        fail "Locale de_DE.UTF-8 fehlt" "sudo locale-gen de_DE.UTF-8"
    fi

    local lang_setting
    lang_setting=$(grep '^LANG=' /etc/default/locale 2>/dev/null || true)
    if [[ "$lang_setting" == "LANG=en_US.UTF-8" ]]; then
        pass "LANG=en_US.UTF-8 in /etc/default/locale gesetzt"
    else
        fail "LANG nicht korrekt gesetzt" "Gefunden: '${lang_setting:-<leer>}'"
    fi
}

#-------------------------------------------------------------------------------
# 4. /etc/wsl.conf
#-------------------------------------------------------------------------------
check_wsl_conf() {
    section "/etc/wsl.conf"

    check_file "/etc/wsl.conf" "/etc/wsl.conf"

    if [[ -f /etc/wsl.conf ]]; then
        if grep -q 'systemd=true' /etc/wsl.conf 2>/dev/null; then
            pass "systemd=true konfiguriert"
        else
            fail "systemd=true fehlt in /etc/wsl.conf"
        fi

        if grep -q 'appendWindowsPath=false' /etc/wsl.conf 2>/dev/null; then
            pass "appendWindowsPath=false konfiguriert"
        else
            fail "appendWindowsPath=false fehlt in /etc/wsl.conf"
        fi

        if grep -q 'generateResolvConf=true' /etc/wsl.conf 2>/dev/null; then
            pass "generateResolvConf=true konfiguriert"
        else
            warn "generateResolvConf=true nicht in /etc/wsl.conf" "Netzwerk-DNS koennte abweichen"
        fi
    fi
}

#-------------------------------------------------------------------------------
# 5. Kernel-Parameter (sysctl)
#-------------------------------------------------------------------------------
check_sysctl() {
    section "Kernel-Parameter (sysctl)"

    check_file "/etc/sysctl.d/99-wsl.conf" "/etc/sysctl.d/99-wsl.conf"

    if [[ -f /etc/sysctl.d/99-wsl.conf ]]; then
        if grep -q 'vm.swappiness=10' /etc/sysctl.d/99-wsl.conf 2>/dev/null; then
            pass "vm.swappiness=10 in 99-wsl.conf"
        else
            fail "vm.swappiness=10 fehlt in /etc/sysctl.d/99-wsl.conf"
        fi

        if grep -q 'vm.vfs_cache_pressure=50' /etc/sysctl.d/99-wsl.conf 2>/dev/null; then
            pass "vm.vfs_cache_pressure=50 in 99-wsl.conf"
        else
            fail "vm.vfs_cache_pressure=50 fehlt in /etc/sysctl.d/99-wsl.conf"
        fi
    fi

    local swappiness
    swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "unbekannt")
    if [[ "$swappiness" == "10" ]]; then
        pass "vm.swappiness aktiv = 10"
    else
        warn "vm.swappiness aktiv = $swappiness" "Erwartet: 10 (nach WSL-Neustart korrekt)"
    fi
}

#-------------------------------------------------------------------------------
# 6. Git-Konfiguration
#-------------------------------------------------------------------------------
check_git() {
    section "Git-Konfiguration"

    check_cmd "git" "git"

    check_git_config "init.defaultBranch" "main"
    check_git_config "core.autocrlf"      "false"
    check_git_config "core.eol"           "lf"
    check_git_config "pull.rebase"        "false"
    check_git_config "push.autoSetupRemote" "true"
    check_git_config "rerere.enabled"     "true"
    check_git_config "diff.colorMoved"    "zebra"

    local git_name
    git_name=$(git config --global --get user.name 2>/dev/null || true)
    if [[ -n "$git_name" ]]; then
        pass "git user.name gesetzt: $git_name"
    else
        warn "git user.name nicht gesetzt" "git config --global user.name 'Dein Name'"
    fi

    local git_email
    git_email=$(git config --global --get user.email 2>/dev/null || true)
    if [[ -n "$git_email" ]]; then
        pass "git user.email gesetzt: $git_email"
    else
        warn "git user.email nicht gesetzt" "git config --global user.email 'deine@email.com'"
    fi
}

#-------------------------------------------------------------------------------
# 7. Shell-Konfiguration (.bashrc)
#-------------------------------------------------------------------------------
check_shell() {
    section "Shell-Konfiguration (.bashrc)"

    check_file "${HOME}/.bashrc" "${HOME}/.bashrc"

    check_file_contains "${HOME}/.bashrc" "# wsl-setup:history" \
        "History-Konfiguration in .bashrc (wsl-setup:history)"

    check_file_contains "${HOME}/.bashrc" "# wsl-setup:aliases" \
        "Aliases in .bashrc (wsl-setup:aliases)"

    check_file_contains "${HOME}/.bashrc" "# wsl-setup:path" \
        "PATH-Erweiterung in .bashrc (wsl-setup:path)"

    check_file_contains "${HOME}/.bashrc" "HISTSIZE=10000" \
        "HISTSIZE=10000 gesetzt"

    check_file_contains "${HOME}/.bashrc" "HISTFILESIZE=20000" \
        "HISTFILESIZE=20000 gesetzt"

    check_file_contains "${HOME}/.bashrc" "HISTCONTROL=ignoreboth:erasedups" \
        "HISTCONTROL=ignoreboth:erasedups gesetzt"

    check_file_contains "${HOME}/.bashrc" 'shopt -s histappend' \
        "histappend aktiviert"

    if echo "${PATH}" | grep -qF "${HOME}/.local/bin"; then
        pass "${HOME}/.local/bin ist im PATH"
    else
        warn "${HOME}/.local/bin nicht im PATH" ".bashrc neu laden: source ${HOME}/.bashrc"
    fi
}

#-------------------------------------------------------------------------------
# 8. Readline (~/.inputrc)
#-------------------------------------------------------------------------------
check_inputrc() {
    section "Readline-Konfiguration (${HOME}/.inputrc)"

    check_file "${HOME}/.inputrc" "${HOME}/.inputrc"

    if [[ -f "${HOME}/.inputrc" ]]; then
        check_file_contains "${HOME}/.inputrc" "history-search-backward" \
            "history-search-backward konfiguriert"

        check_file_contains "${HOME}/.inputrc" "completion-ignore-case on" \
            "completion-ignore-case aktiviert"

        check_file_contains "${HOME}/.inputrc" "colored-stats on" \
            "colored-stats aktiviert"
    fi
}

#-------------------------------------------------------------------------------
# 9. SSH
#-------------------------------------------------------------------------------
check_ssh() {
    section "SSH-Konfiguration"

    check_dir "${HOME}/.ssh" "${HOME}/.ssh"

    if [[ -d "${HOME}/.ssh" ]]; then
        local ssh_perms
        ssh_perms=$(stat -c '%a' "${HOME}/.ssh" 2>/dev/null || echo "unbekannt")
        if [[ "$ssh_perms" == "700" ]]; then
            pass "${HOME}/.ssh Berechtigungen: 700"
        else
            fail "${HOME}/.ssh Berechtigungen falsch: $ssh_perms" "chmod 700 ${HOME}/.ssh"
        fi
    fi

    check_file "${HOME}/.ssh/config" "${HOME}/.ssh/config"

    if [[ -f "${HOME}/.ssh/config" ]]; then
        local config_perms
        config_perms=$(stat -c '%a' "${HOME}/.ssh/config" 2>/dev/null || echo "unbekannt")
        if [[ "$config_perms" == "600" ]]; then
            pass "${HOME}/.ssh/config Berechtigungen: 600"
        else
            fail "${HOME}/.ssh/config Berechtigungen falsch: $config_perms" \
                "chmod 600 ${HOME}/.ssh/config"
        fi

        check_file_contains "${HOME}/.ssh/config" "ServerAliveInterval 60" \
            "ServerAliveInterval 60 in SSH-Config"

        check_file_contains "${HOME}/.ssh/config" "github.com" \
            "GitHub-Host in SSH-Config konfiguriert"
    fi

    if [[ -f "${HOME}/.ssh/id_ed25519" ]]; then
        pass "SSH-Key vorhanden: ${HOME}/.ssh/id_ed25519"
        if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
            pass "SSH-Public-Key vorhanden: ${HOME}/.ssh/id_ed25519.pub"
        else
            fail "SSH-Public-Key fehlt: ${HOME}/.ssh/id_ed25519.pub"
        fi
    else
        warn "SSH-Key nicht vorhanden: ${HOME}/.ssh/id_ed25519" \
            "Optional: ssh-keygen -t ed25519 -C 'deine@email.com'"
    fi
}

#-------------------------------------------------------------------------------
# 10. Full-Mode: CLI-Tools (apt)
#-------------------------------------------------------------------------------
check_cli_tools_apt() {
    section "CLI-Tools (apt)"

    local -a apt_tools=(ripgrep fd-find bat fzf tmux ncdu direnv git-delta)
    local tool
    for tool in "${apt_tools[@]}"; do
        check_pkg "$tool"
    done
}

#-------------------------------------------------------------------------------
# 11. Full-Mode: CLI-Tools (Binaries)
#-------------------------------------------------------------------------------
check_cli_tools_binaries() {
    section "CLI-Tools (Binaries / Symlinks)"

    # bat: Ubuntu installiert als batcat, Setup erstellt Symlink 'bat'
    if command -v bat &>/dev/null; then
        pass "bat verfuegbar: $(command -v bat)"
    elif command -v batcat &>/dev/null; then
        fail "bat-Symlink fehlt" "ln -sf $(command -v batcat) ${HOME}/.local/bin/bat"
    else
        fail "bat nicht verfuegbar" "sudo apt-get install -y bat"
    fi

    # fd: Ubuntu installiert als fdfind, Setup erstellt Symlink 'fd'
    if command -v fd &>/dev/null; then
        pass "fd verfuegbar: $(command -v fd)"
    elif command -v fdfind &>/dev/null; then
        fail "fd-Symlink fehlt" "ln -sf $(command -v fdfind) ${HOME}/.local/bin/fd"
    else
        fail "fd nicht verfuegbar" "sudo apt-get install -y fd-find"
    fi

    # eza (via GitHub Releases)
    if command -v eza &>/dev/null; then
        pass "eza verfuegbar: $(command -v eza)"
        check_file_contains "${HOME}/.bashrc" "# wsl-setup:eza" \
            "eza-Aliases in .bashrc gesetzt"
    else
        fail "eza nicht gefunden" "Erwartet in ${HOME}/.local/bin/eza"
    fi

    # zoxide
    if command -v zoxide &>/dev/null; then
        pass "zoxide verfuegbar: $(command -v zoxide)"
        check_file_contains "${HOME}/.bashrc" "# wsl-setup:zoxide" \
            "zoxide-Init in .bashrc gesetzt"
    else
        fail "zoxide nicht gefunden" \
            "Installation: tmp=\$(mktemp) && curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh -o \$tmp && bash \$tmp && rm -f \$tmp"
    fi

    # gh (GitHub CLI)
    if command -v gh &>/dev/null; then
        pass "gh (GitHub CLI) verfuegbar: $(command -v gh)"
    else
        fail "gh nicht gefunden" "Via apt: sudo apt-get install gh"
    fi

    # yq
    if command -v yq &>/dev/null; then
        pass "yq verfuegbar: $(command -v yq)"
    else
        fail "yq nicht gefunden" "Erwartet in ${HOME}/.local/bin/yq"
    fi

    # lazygit
    if command -v lazygit &>/dev/null; then
        pass "lazygit verfuegbar: $(command -v lazygit)"
    else
        fail "lazygit nicht gefunden" "Erwartet in ${HOME}/.local/bin/lazygit"
    fi

    # tmux (Befehl)
    check_cmd "tmux" "tmux"

    # direnv (Befehl)
    check_cmd "direnv" "direnv"

    # fzf (Befehl)
    check_cmd "fzf" "fzf"

    # delta
    if command -v delta &>/dev/null; then
        pass "delta (git-delta) verfuegbar: $(command -v delta)"
        local pager
        pager=$(git config --global --get core.pager 2>/dev/null || true)
        if [[ "$pager" == "delta" ]]; then
            pass "delta als git-Pager konfiguriert"
        else
            fail "delta nicht als git-Pager gesetzt" "git config --global core.pager delta"
        fi
    else
        fail "delta nicht gefunden" "sudo apt-get install -y git-delta"
    fi
}

#-------------------------------------------------------------------------------
# 12. Full-Mode: Browser-Integration
#-------------------------------------------------------------------------------
check_browser_integration() {
    section "Browser-Integration"

    check_pkg "xdg-utils"

    if command -v wslview &>/dev/null; then
        pass "wslview verfuegbar (wslu)"
    else
        if dpkg -l wslu 2>/dev/null | grep -q '^ii'; then
            pass "Paket installiert: wslu"
        else
            warn "wslu nicht installiert" "sudo apt-get install -y wslu"
        fi
    fi
}

#-------------------------------------------------------------------------------
# 13. Full-Mode: Dev-Dependencies
#-------------------------------------------------------------------------------
check_dev_dependencies() {
    section "Dev-Dependencies"

    local -a dev_pkgs=(
        gcc g++ gdb clang clang-format clang-tidy lldb
        cmake make ninja-build
        sqlite3 postgresql-client
        jq tree file htop shellcheck
    )

    local pkg
    for pkg in "${dev_pkgs[@]}"; do
        check_pkg "$pkg"
    done
}

#-------------------------------------------------------------------------------
# 14. Full-Mode: Python + uv
#-------------------------------------------------------------------------------
check_python() {
    section "Python + uv"

    check_pkg "python3"
    check_pkg "python3-pip"
    check_pkg "python3-venv"
    check_pkg "python3-dev"

    check_cmd "python3" "python3"

    local py_version
    py_version=$(python3 --version 2>/dev/null | cut -d' ' -f2 || echo "unbekannt")
    pass "Python-Version: $py_version"

    if command -v uv &>/dev/null; then
        pass "uv verfuegbar: $(command -v uv)"
    else
        fail "uv nicht gefunden" "Installation: tmp=\$(mktemp) && curl -fsSL https://astral.sh/uv/install.sh -o \$tmp && bash \$tmp && rm -f \$tmp"
    fi

    check_file "${HOME}/.config/pip/pip.conf" "${HOME}/.config/pip/pip.conf"
}

#-------------------------------------------------------------------------------
# 15. Full-Mode: Node.js + nvm + pnpm
#-------------------------------------------------------------------------------
check_nodejs() {
    section "Node.js / nvm / pnpm"

    check_dir "${HOME}/.nvm" "${HOME}/.nvm"
    check_file "${HOME}/.nvm/nvm.sh" "${HOME}/.nvm/nvm.sh"

    if [[ -s "${HOME}/.nvm/nvm.sh" ]]; then
        # nvm in aktueller Shell laden
        export NVM_DIR="${HOME}/.nvm"
        # shellcheck source=/dev/null
        source "${HOME}/.nvm/nvm.sh"

        if command -v node &>/dev/null; then
            local node_ver
            node_ver=$(node --version 2>/dev/null || echo "unbekannt")
            pass "Node.js verfuegbar: $node_ver"
        else
            fail "node nicht im PATH nach nvm-Init" "nvm install --lts"
        fi

        if command -v npm &>/dev/null; then
            pass "npm verfuegbar: $(npm --version 2>/dev/null || echo '?')"
        else
            fail "npm nicht verfuegbar"
        fi

        if command -v pnpm &>/dev/null; then
            pass "pnpm verfuegbar: $(pnpm --version 2>/dev/null || echo '?')"
        else
            fail "pnpm nicht gefunden" "npm install -g pnpm"
        fi
    else
        fail "${HOME}/.nvm/nvm.sh nicht vorhanden oder leer" "nvm-Installation fehlgeschlagen"
    fi

    # nvm-Init in .bashrc pruefen
    if grep -q 'NVM_DIR' "${HOME}/.bashrc" 2>/dev/null; then
        pass "nvm-Init in .bashrc vorhanden"
    else
        fail "nvm-Init fehlt in .bashrc" "Muss NVM_DIR und nvm.sh source enthalten"
    fi
}

#-------------------------------------------------------------------------------
# 16. Full-Mode: tmux-Konfiguration
#-------------------------------------------------------------------------------
check_tmux_config() {
    section "tmux-Konfiguration"

    check_file "${HOME}/.tmux.conf" "${HOME}/.tmux.conf"

    if [[ -f "${HOME}/.tmux.conf" ]]; then
        check_file_contains "${HOME}/.tmux.conf" "set -g prefix C-a" \
            "tmux Prefix Ctrl+a konfiguriert"

        check_file_contains "${HOME}/.tmux.conf" "set -g mouse on" \
            "tmux Maus aktiviert"

        check_file_contains "${HOME}/.tmux.conf" "set -g base-index 1" \
            "tmux Fenster-Nummerierung ab 1"

        check_file_contains "${HOME}/.tmux.conf" "set -g history-limit 10000" \
            "tmux History-Puffer 10000"

        check_file_contains "${HOME}/.tmux.conf" "setw -g mode-keys vi" \
            "tmux Vi-Modus aktiviert"
    fi
}

#-------------------------------------------------------------------------------
# 17. Full-Mode: zsh + Oh-My-Zsh
#-------------------------------------------------------------------------------
check_zsh() {
    section "zsh + Oh-My-Zsh"

    check_cmd "zsh" "zsh"

    local zsh_bin
    zsh_bin=$(command -v zsh 2>/dev/null || echo "")

    if [[ -n "$zsh_bin" ]]; then
        local current_shell
        current_shell=$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || true)
        if [[ "$current_shell" == "$zsh_bin" ]]; then
            pass "zsh ist Default-Shell: $current_shell"
        else
            warn "zsh ist nicht Default-Shell" \
                "Aktuell: '${current_shell:-unbekannt}'. Erwartet: '$zsh_bin'"
        fi
    fi

    check_dir "${HOME}/.oh-my-zsh" "${HOME}/.oh-my-zsh"

    local zsh_custom="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"

    check_dir "${zsh_custom}/plugins/zsh-autosuggestions" \
        "Oh-My-Zsh Plugin: zsh-autosuggestions"

    check_dir "${zsh_custom}/plugins/zsh-syntax-highlighting" \
        "Oh-My-Zsh Plugin: zsh-syntax-highlighting"

    check_file "${HOME}/.zshrc" "${HOME}/.zshrc"

    if [[ -f "${HOME}/.zshrc" ]]; then
        if grep -q 'zsh-autosuggestions' "${HOME}/.zshrc" 2>/dev/null; then
            pass "zsh-autosuggestions in plugins= aktiviert"
        else
            fail "zsh-autosuggestions nicht in .zshrc plugins=" \
                "plugins=(git zsh-autosuggestions zsh-syntax-highlighting)"
        fi

        if grep -q 'zsh-syntax-highlighting' "${HOME}/.zshrc" 2>/dev/null; then
            pass "zsh-syntax-highlighting in plugins= aktiviert"
        else
            fail "zsh-syntax-highlighting nicht in .zshrc plugins=" \
                "plugins=(git zsh-autosuggestions zsh-syntax-highlighting)"
        fi

        check_file_contains "${HOME}/.zshrc" "# wsl-setup:zsh-path" \
            "PATH-Erweiterung in .zshrc gesetzt"
    fi
}

#-------------------------------------------------------------------------------
# 18. Full-Mode: pwsh (PowerShell Core)
#-------------------------------------------------------------------------------
check_pwsh() {
    section "PowerShell Core (pwsh)"

    if command -v pwsh &>/dev/null; then
        local pwsh_ver
        pwsh_ver=$(pwsh --version 2>/dev/null | cut -d' ' -f2 || echo "unbekannt")
        pass "pwsh verfuegbar: $pwsh_ver"
    else
        fail "pwsh nicht gefunden" "Via Microsoft apt-Repo installieren"
    fi
}

#-------------------------------------------------------------------------------
# 19. Full-Mode: ~/.local/bin Symlinks
#-------------------------------------------------------------------------------
check_local_bin() {
    section "${HOME}/.local/bin (Symlinks / Binaries)"

    check_dir "${HOME}/.local/bin" "${HOME}/.local/bin"

    local -a expected_bins=(eza yq lazygit)
    local bin
    for bin in "${expected_bins[@]}"; do
        if [[ -x "${HOME}/.local/bin/${bin}" ]]; then
            pass "${HOME}/.local/bin/$bin vorhanden und ausfuehrbar"
        else
            fail "${HOME}/.local/bin/$bin fehlt oder nicht ausfuehrbar"
        fi
    done

    # Symlinks: bat und fd (Ubuntu-spezifisch)
    local link
    for link in bat fd; do
        if [[ -L "${HOME}/.local/bin/${link}" ]]; then
            pass "${HOME}/.local/bin/$link: Symlink vorhanden"
        elif [[ -x "${HOME}/.local/bin/${link}" ]]; then
            pass "${HOME}/.local/bin/$link: Binary vorhanden"
        else
            fail "${HOME}/.local/bin/$link: Symlink/Binary fehlt"
        fi
    done
}

#-------------------------------------------------------------------------------
# Zusammenfassung
#-------------------------------------------------------------------------------
show_summary() {
    local total=$(( PASS_COUNT + FAIL_COUNT + WARN_COUNT ))

    printf '\n%b%s%b\n' "${BOLD}" \
        "===============================================================================" "${NC}"
    printf '%b  Validierungs-Ergebnis%b\n' "${BOLD}" "${NC}"
    printf '%b%s%b\n\n' "${BOLD}" \
        "===============================================================================" "${NC}"

    printf '  %b[PASS]%b %d von %d Checks bestanden\n' \
        "${GREEN}" "${NC}" "${PASS_COUNT}" "${total}"

    if [[ "${WARN_COUNT}" -gt 0 ]]; then
        printf '  %b[WARN]%b %d Warnung(en) – keine Fehler, aber zu pruefen\n' \
            "${YELLOW}" "${NC}" "${WARN_COUNT}"
    fi

    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        printf '  %b[FAIL]%b %d Check(s) fehlgeschlagen\n' \
            "${RED}" "${NC}" "${FAIL_COUNT}"
        printf '\n  %bAktion:%b Setup-Script erneut ausfuehren oder Einzel-Schritte pruefen.\n' \
            "${YELLOW}" "${NC}"
    fi

    printf '\n%b%s%b\n\n' "${BOLD}" \
        "===============================================================================" "${NC}"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"

    printf '\n%b  Ubuntu WSL2 Setup – Validierung%b\n' "${CYAN}" "${NC}"
    printf '%b  Modus: %s%b\n' "${DIM}" "${MODE}" "${NC}"

    # Immer ausgefuehrt (Basis)
    check_wsl_environment
    check_base_packages
    check_locale
    check_wsl_conf
    check_sysctl
    check_git
    check_shell
    check_inputrc
    check_ssh

    # Full-Mode Extras
    if [[ "${MODE}" == "--full" ]]; then
        check_cli_tools_apt
        check_cli_tools_binaries
        check_local_bin
        check_browser_integration
        check_dev_dependencies
        check_python
        check_nodejs
        check_tmux_config
        check_zsh
        check_pwsh
    fi

    show_summary

    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
