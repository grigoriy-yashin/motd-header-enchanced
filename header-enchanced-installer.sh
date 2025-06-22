#!/bin/bash
set -e

SCRIPT_NAME="01-header-advanced"
INSTALL_PATH="/etc/update-motd.d/$SCRIPT_NAME"
ASSETS_DIR="/etc/update-motd.d/assets"
DISABLED_DIR="/etc/update-motd.d/disabled"
LOGO_FILE="$ASSETS_DIR/logo.txt"
WIDTH_DEFAULT=30
MAX_WIDTH="$WIDTH_DEFAULT"

# Default ASCII logo content
read -r -d '' DEFAULT_LOGO_CONTENT << 'EOL'
# <--- Insert your multiline ASCII logo here --->
EOL

show_help() {
    cat <<EOF
Usage:
  sudo $0 install [--max-logo-width WIDTH] [--with-landscape]
  sudo $0 --uninstall [--purge]

Options:
  --max-logo-width N    Set max logo width to determine layout (default: $WIDTH_DEFAULT)
  --with-landscape      Install landscape-sysinfo if missing
  --uninstall           Uninstall the MOTD script
  --purge               Remove all installed files (logo, disabled scripts)
  -h, --help            Show this help message
EOF
}

ensure_dir() {
    [ -d "$1" ] || mkdir -p "$1"
}

install_landscape() {
    if ! command -v landscape-sysinfo >/dev/null 2>&1; then
        apt-get update && apt-get install -y landscape-common
    fi
}

move_script_to_disabled() {
    for f in /etc/update-motd.d/00-header /etc/update-motd.d/50-landscape-sysinfo; do
        if [ -f "$f" ]; then
            ensure_dir "$DISABLED_DIR"
            mv -f "$f" "$DISABLED_DIR/"
        fi
    done
}

restore_disabled_scripts() {
    if [ -d "$DISABLED_DIR" ]; then
        mv -f "$DISABLED_DIR"/* /etc/update-motd.d/ 2>/dev/null || true
    fi
}

install_logo() {
    ensure_dir "$ASSETS_DIR"
    if [ ! -f "$LOGO_FILE" ]; then
        echo "$DEFAULT_LOGO_CONTENT" > "$LOGO_FILE"
    fi
}

purge_all() {
    rm -f "$INSTALL_PATH"
    [ -d "$ASSETS_DIR" ] && rm -rf "$ASSETS_DIR"
    [ -d "$DISABLED_DIR" ] && rm -rf "$DISABLED_DIR"
}

embed_script() {
    cat <<'EOF' > "$INSTALL_PATH"
#!/bin/bash
WIDTH=${WIDTH:-30}  # fallback default
# === Embedded MOTD Script Starts Here ===
# Insert full MOTD script content here with updated WIDTH variable
# You can paste the entire updated MOTD script content below
EOF
    chmod +x "$INSTALL_PATH"
    sed -i "s/^WIDTH=.*/WIDTH=$MAX_WIDTH/" "$INSTALL_PATH" || true
}

# === ARGUMENT PARSING ===
ACTION=""
WITH_LANDSCAPE=0
PURGE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        install)
            ACTION="install"
            ;;
        --uninstall)
            ACTION="uninstall"
            ;;
        --purge)
            PURGE=1
            ;;
        --with-landscape)
            WITH_LANDSCAPE=1
            ;;
        --max-logo-width)
            MAX_WIDTH="$2"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

case "$ACTION" in
    install)
        embed_script
        install_logo
        move_script_to_disabled
        [ "$WITH_LANDSCAPE" -eq 1 ] && install_landscape
        echo "Installed $SCRIPT_NAME with logo width limit $MAX_WIDTH"
        ;;
    uninstall)
        rm -f "$INSTALL_PATH"
        restore_disabled_scripts
        [ "$PURGE" -eq 1 ] && purge_all
        echo "Uninstalled $SCRIPT_NAME"
        ;;
    *)
        show_help
        exit 1
        ;;
esac
