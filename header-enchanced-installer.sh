#!/bin/bash
set -e

SCRIPT_NAME="01-header-advanced"
INSTALL_PATH="/etc/update-motd.d/$SCRIPT_NAME"
ASSETS_DIR="/etc/update-motd.d/assets"
DISABLED_DIR="/etc/update-motd.d/disabled"
LOGO_FILE="$ASSETS_DIR/logo.txt"
WIDTH_DEFAULT=30
MAX_WIDTH="$WIDTH_DEFAULT"

DEFAULT_LOGO_CONTENT="$(cat <<'EOF'
 
          -%%%%%%%%%%:         
       #%%%%%%%%%%%%%%%%*      
     %%%%%%%%%%%%%%*  +%%%#    
   =%%%%%%%%%+:  :%    %%%%%:  
  #%%%%%%% :*      =%%%%%%%%%= 
 :%%%%%%.   #%%%%%%+   +%%%%%% 
 %%%%%%*  .%%%%%%%%%%   #%%%%%*
 %%%   -  %%%%%%%%%%%% .*%%%%%%
 %%%   =  %%%%%%%%%%%#  =%%%%%%
 %%%%%%#   %%%%%%%%%%   %%%%%%*
 .%%%%%%=   *%%%%%%.   %%%%%%% 
  +%%%%%%%.+=      #*+%%%%%%%: 
   :%%%%%%%%%*=--=%    %%%%%.  
     #%%%%%%%%%%%%%%..#%%%*    
       +%%%%%%%%%%%%%%%%-      
           +%%%%%%%%=          
                               
EOF
)"

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

###############################################################################
# MOTD: ASCII logo + dynamic sysinfo entries with cache logic from 50-landscape
###############################################################################

WIDTH=${WIDTH:-30}  # fallback default
ASSET_LOGO_PATH="/etc/update-motd.d/assets/logo.txt"
CACHE="/var/lib/landscape/landscape-sysinfo.cache"

ENTRIES=()
ENTRIES+=("Welcome to $(lsb_release -d | cut -f2-)")
ENTRIES+=("($(uname -o) $(uname -r) $(uname -m))")
ENTRIES+=(" ")

STATIC_COUNT=${#ENTRIES[@]}

# === 1. Load system info from landscape-sysinfo with caching ===
if [ -x /usr/bin/landscape-sysinfo ]; then
    HAS_CACHE="FALSE"
    CACHE_NEEDS_UPDATE="FALSE"
    [ -r "$CACHE" ] && HAS_CACHE="TRUE"
    [ -z "$(find "$CACHE" -newermt 'now-1 minutes' 2> /dev/null)" ] && CACHE_NEEDS_UPDATE="TRUE"

    if [ "$HAS_CACHE" = "TRUE" ] && [ "$CACHE_NEEDS_UPDATE" = "FALSE" ]; then
        SYSINFO_OUTPUT=$(cat "$CACHE")
    else
        SYSINFO_OUTPUT=""
        [ -f /etc/default/locale ] && . /etc/default/locale
        export LANG
        CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
        [ "$CORES" -eq "0" ] && CORES=1
        THRESHOLD="${CORES:-1}.0"

        if [ "$(echo "$(cut -f1 -d ' ' /proc/loadavg) < $THRESHOLD" | bc)" -eq 1 ]; then
            SYSINFO_OUTPUT=$(printf "\n System information as of %s\n\n%s\n" \
                "$(/bin/date)" \
                "$(/usr/bin/landscape-sysinfo)")
            echo "$SYSINFO_OUTPUT" >"$CACHE" 2>/dev/null || true
            chmod 0644 "$CACHE" 2>/dev/null || true
        else
            SYSINFO_OUTPUT=$(printf "\n System information disabled due to load higher than %s\n" "$THRESHOLD")
            if [ "$HAS_CACHE" = "TRUE" ]; then
                if ! grep -q " System information as of" "$CACHE"; then
                    echo "$SYSINFO_OUTPUT" >"$CACHE" 2>/dev/null || true
                    chmod 0644 "$CACHE" 2>/dev/null || true
                else
                    SYSINFO_OUTPUT=$(cat "$CACHE")
                fi
            fi
        fi
    fi

    # === 1.1 Parse selected fields from landscape-sysinfo ===
    wanted_keys=(
        "System load:"
        "Usage of /:"
        "Memory usage:"
        "Swap usage:"
        "Processes:"
        "Users logged in:"
        "IPv4 address for"
        "Temperature:"
    )

    while IFS= read -r line; do
        field_positions=()
        for key in "${wanted_keys[@]}"; do
            pos=$(awk -v a="$line" -v b="$key" 'BEGIN{print index(a,b)}')
            [ "$pos" -gt 0 ] && field_positions+=("$pos:$key")
        done

        if [ "${#field_positions[@]}" -eq 1 ]; then
            key=${field_positions[0]#*:}
            val=${line#*$key}
            ENTRIES+=("$key$val")
        elif [ "${#field_positions[@]}" -gt 1 ]; then
            IFS=$'\n' sorted=($(printf '%s\n' "${field_positions[@]}" | sort -n))
            for i in "${!sorted[@]}"; do
                pos=${sorted[$i]%%:*}
                key=${sorted[$i]#*:}
                start=$pos
                if [ $i -lt $((${#sorted[@]} - 1)) ]; then
                    next_pos=${sorted[$((i+1))]%%:*}
                    length=$((next_pos - pos))
                    chunk=${line:$start-1:$length}
                else
                    chunk=${line:$start-1}
                fi
                trimmed=$(echo "$chunk" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
                ENTRIES+=("$trimmed")
            done
        fi
    done <<< "$SYSINFO_OUTPUT"
fi

# === 2. Load ASCII logo ===
if [ ! -f "$ASSET_LOGO_PATH" ]; then
    echo "ERROR: Logo file not found at $ASSET_LOGO_PATH"
    exit 1
fi

IFS=$'\n' read -r -d '' -a LOGO_LINES < "$ASSET_LOGO_PATH"
LOGO_HEIGHT=${#LOGO_LINES[@]}
LOGO_WIDTH=$(printf '%s\n' "${LOGO_LINES[@]}" | awk '{print length}' | sort -nr | head -n1)
ENTRIES_HEIGHT=${#ENTRIES[@]}

# === Function: Print logo and two-column sysinfo ===
print_header_and_sysinfo() {
    [ -r /etc/lsb-release ] && . /etc/lsb-release
    [ -z "$DISTRIB_DESCRIPTION" ] && [ -x /usr/bin/lsb_release ] && DISTRIB_DESCRIPTION=$(lsb_release -s -d)

    printf "Welcome to %s (%s %s %s)\n\n" "$DISTRIB_DESCRIPTION" "$(uname -o)" "$(uname -r)" "$(uname -m)"
    printf '%s\n' "${LOGO_LINES[@]}"

    sys_entries=("${ENTRIES[@]:$STATIC_COUNT}")
    [ "${#sys_entries[@]}" -gt 0 ] && printf " System information as of %s\n\n" "$(/bin/date)"

    half=$(( (${#sys_entries[@]} + 1) / 2 ))
    LEFT=("${sys_entries[@]:0:$half}")
    RIGHT=("${sys_entries[@]:$half}")

    parse_column() {
        local entries=("$@")
        local keys=()
        local values=()
        local max_key=0
        for line in "${entries[@]}"; do
            key="${line%%:*}:"
            val="$(echo "${line#*:}" | sed 's/^[[:space:]]*//')"
            keys+=("$key")
            values+=("$val")
            [ ${#key} -gt $max_key ] && max_key=${#key}
        done
        echo "$(IFS=$'\n'; echo "${keys[*]}")" > /tmp/keys
        echo "$(IFS=$'\n'; echo "${values[*]}")" > /tmp/vals
        echo "$max_key" > /tmp/max
    }

    parse_column "${LEFT[@]}"
    LEFT_KEYS=($(< /tmp/keys))
    LEFT_VALUES=($(< /tmp/vals))
    LEFT_WIDTH=$(< /tmp/max)

    parse_column "${RIGHT[@]}"
    RIGHT_KEYS=($(< /tmp/keys))
    RIGHT_VALUES=($(< /tmp/vals))
    RIGHT_WIDTH=$(< /tmp/max)

    MAX_LEFT_LINE=0
    for i in "${!LEFT_KEYS[@]}"; do
        len=$(( ${#LEFT_KEYS[i]} + 1 + ${#LEFT_VALUES[i]} ))
        [ "$len" -gt "$MAX_LEFT_LINE" ] && MAX_LEFT_LINE=$len
    done

    for i in $(seq 0 $((half - 1))); do
        LEFT_LINE=$(printf "%-*s %s" "$LEFT_WIDTH" "${LEFT_KEYS[$i]}" "${LEFT_VALUES[$i]}")
        printf "  %s" "$LEFT_LINE"
        if [ -n "${RIGHT_KEYS[$i]}" ]; then
            SPACES=$(( MAX_LEFT_LINE - ${#LEFT_LINE} + 4 ))
            printf "%*s%-*s %s" "$SPACES" "" "$RIGHT_WIDTH" "${RIGHT_KEYS[$i]}" "${RIGHT_VALUES[$i]}"
        fi
        echo
    done
}

# === 3. Wide logo logic ===
if [ "$LOGO_WIDTH" -gt "$WIDTH" ]; then
    print_header_and_sysinfo
    exit 0
fi

# === 4. Tall logo: logo on left, sysinfo on right ===
if [ "$LOGO_HEIGHT" -ge "$ENTRIES_HEIGHT" ]; then
    for i in "${!LOGO_LINES[@]}"; do
        if [ $i -lt "$ENTRIES_HEIGHT" ]; then
            printf "%s   %s\n" "${LOGO_LINES[$i]}" "${ENTRIES[$i]}"
        else
            printf "%s\n" "${LOGO_LINES[$i]}"
        fi
    done
    exit 0
fi

# === 5. Short and narrow logo with header on the right ===
if [ "$LOGO_HEIGHT" -lt "$ENTRIES_HEIGHT" ]; then
    WELCOME="${ENTRIES[0]}"
    KERNEL="${ENTRIES[1]}"
    PAD="   "  # Padding between logo and text

    for i in "${!LOGO_LINES[@]}"; do
        LINE="${LOGO_LINES[$i]}"
        if [ $i -eq 0 ]; then
            printf "%s%s%s\n" "$LINE" "$PAD" "$WELCOME"
        elif [ $i -eq 1 ]; then
            printf "%s%s%s\n" "$LINE" "$PAD" "$KERNEL"
        else
            printf "%s\n" "$LINE"
        fi
    done

    # Print system info entries (excluding header)
    sys_entries=("${ENTRIES[@]:$STATIC_COUNT}")
    [ "${#sys_entries[@]}" -gt 0 ] && printf " System information as of %s\n\n" "$(/bin/date)"

    half=$(( (${#sys_entries[@]} + 1) / 2 ))
    LEFT=("${sys_entries[@]:0:$half}")
    RIGHT=("${sys_entries[@]:$half}")

    parse_column() {
        local entries=("$@")
        local keys=()
        local values=()
        local max_key=0
        for line in "${entries[@]}"; do
            key="${line%%:*}:"
            val="$(echo "${line#*:}" | sed 's/^[[:space:]]*//')"
            keys+=("$key")
            values+=("$val")
            [ ${#key} -gt $max_key ] && max_key=${#key}
        done
        echo "$(IFS=$'\n'; echo "${keys[*]}")" > /tmp/keys
        echo "$(IFS=$'\n'; echo "${values[*]}")" > /tmp/vals
        echo "$max_key" > /tmp/max
    }

    parse_column "${LEFT[@]}"
    LEFT_KEYS=($(< /tmp/keys))
    LEFT_VALUES=($(< /tmp/vals))
    LEFT_WIDTH=$(< /tmp/max)

    parse_column "${RIGHT[@]}"
    RIGHT_KEYS=($(< /tmp/keys))
    RIGHT_VALUES=($(< /tmp/vals))
    RIGHT_WIDTH=$(< /tmp/max)

    MAX_LEFT_LINE=0
    for i in "${!LEFT_KEYS[@]}"; do
        len=$(( ${#LEFT_KEYS[i]} + 1 + ${#LEFT_VALUES[i]} ))
        [ "$len" -gt "$MAX_LEFT_LINE" ] && MAX_LEFT_LINE=$len
    done

    for i in $(seq 0 $((half - 1))); do
        LEFT_LINE=$(printf "%-*s %s" "$LEFT_WIDTH" "${LEFT_KEYS[$i]}" "${LEFT_VALUES[$i]}")
        printf "  %s" "$LEFT_LINE"
        if [ -n "${RIGHT_KEYS[$i]}" ]; then
            SPACES=$(( MAX_LEFT_LINE - ${#LEFT_LINE} + 4 ))
            printf "%*s%-*s %s" "$SPACES" "" "$RIGHT_WIDTH" "${RIGHT_KEYS[$i]}" "${RIGHT_VALUES[$i]}"
        fi
        echo
    done
    exit 0
fi

# === 6. Default: short logo logic (fallback) ===
print_header_and_sysinfo
exit 0

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
