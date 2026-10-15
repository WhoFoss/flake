#!/usr/bin/env bash

set -u

######################################################################
#---------------------------- VARIABLES -----------------------------#
######################################################################

config_file=""
socks_host="127.0.0.1"
socks_port="9050"
timeout_secs=60
tor_pid=""
tor_log=""
datadir=""
sleep_pid=""
interval=0
ctrl_port="9051"

######################################################################
#------------------------------ COLORS ------------------------------#
######################################################################

if [ -n "${TERM:-}" ] && command -v tput >/dev/null 2>&1; then
    green=$(tput setaf 2)
    red=$(tput setaf 1)
    white=$(tput setaf 7)
    bold=$(tput bold)
    underline=$(tput smul)
    reverse=$(tput rev)
    reset=$(tput sgr0)
    cursor_off=$(tput civis)
    cursor_on=$(tput cnorm)
    highlight="$(tput setab 7)$(tput setaf 0)"
else
    green=""
    red=""
    white=""
    bold=""
    underline=""
    reverse=""
    reset=""
    cursor_off=""
    cursor_on=""
    highlight=""
fi

######################################################################
#----------------------------- MESSAGES -----------------------------#
######################################################################

# Print a success message in green
success() {
    printf '%s%s%s\n' "$green" "$1" "$reset"
}

# Print an informational message in white
info() {
    printf '%s%s%s\n' "$white" "$1" "$reset"
}

# Print an error message in red and exit the script
error() {
    printf '%s%s%s\n' "${bold}${red}" "$1" "$reset" >&2
    exit 1
}

# Print how the script should be used
usage() {
    printf '%sUsage:%s %s %soption%s\n\n' "$bold" "$reset" "${0##*/}" "$underline" "$reset"
    printf '%sOptions:%s\n' "$bold" "$reset"
    printf '  %s%-8s%s %s\n' "$bold" "-c" "$reset" "Configure proxychains to use Tor (socks5 ${socks_host}:${socks_port})"
    printf '  %s%-8s%s %s\n' "$bold" "-t" "$reset" "Start Tor in the background and follow the connection"
    printf '  %s%-8s%s %s\n' "$bold" "-r [s]" "$reset" "Like -t, changing IP every s seconds"
    printf '  %-8s %s\n' "" "(default 60, minimum 10)"
    printf '  %s%-8s%s %s\n' "$bold" "-h" "$reset" "Show this help"
}

######################################################################
#--------------------------- DEPENDENCIES ---------------------------#
######################################################################

# Check that the dependencies given as arguments are installed
check_dependencies() {
    local dep missing=""
    for dep in "$@"; do
        command -v "$dep" >/dev/null 2>&1 || missing="${missing:+$missing }$dep"
    done
    [ -z "$missing" ] && return 0

    printf '%s%s%s\n' "${bold}${red}" "Missing dependencies: ${missing}" "$reset" >&2
    if [ -d /data/data/com.termux ]; then
        info "Install with: pkg install tor proxychains-ng curl coreutils" >&2
    else
        info "Install with: sudo apt install tor proxychains4 curl coreutils" >&2
    fi
    exit 1
}

######################################################################
#------------------------- PROXYCHAINS (-c) -------------------------#
######################################################################

# Locate the proxychains configuration file (Termux or Linux)
detect_config() {
    local candidate
    for candidate in "${PREFIX:-}/etc/proxychains.conf" /etc/proxychains4.conf /etc/proxychains.conf; do
        if [ -f "$candidate" ]; then
            config_file="$candidate"
            return 0
        fi
    done
    error "Proxychains configuration file not found."
}

# Make sure the file is writable (outside Termux this needs sudo)
check_permission() {
    [ -w "$config_file" ] || error "No write permission on $config_file. Run with sudo."
}

# Apply the changes to the configuration file
apply_config() {
    sed -i 's/^strict_chain/#strict_chain/' "$config_file"
    success "Strict chain disabled."

    sed -i 's/^#dynamic_chain[[:space:]]*$/dynamic_chain/' "$config_file"
    success "Dynamic chain enabled."

    sed -i 's/^#proxy_dns[[:space:]]*$/proxy_dns/' "$config_file"
    sed -i -E 's/^(proxy_dns_old|proxy_dns_daemon)/#\1/' "$config_file"
    if ! grep -Eq '^proxy_dns[[:space:]]*$' "$config_file"; then
        sed -i '/^\[ProxyList\]/i proxy_dns' "$config_file"
    fi
    success "Proxy DNS enabled (no DNS leaks)."

    sed -i -E 's/^(socks4[[:space:]]+127\.0\.0\.1[[:space:]]+(9050|9095))/#\1/' "$config_file"
    if ! grep -Eq "^socks5[[:space:]]+${socks_host//./\\.}[[:space:]]+${socks_port}" "$config_file"; then
        if [ -n "$(tail -c1 "$config_file")" ]; then
            printf '\n' >> "$config_file"
        fi
        printf 'socks5 %s %s\n' "$socks_host" "$socks_port" >> "$config_file"
    fi
    success "Socks5 proxy configured at ${socks_host}:${socks_port}."
}

# Confirm that every change is active in the file
verify_result() {
    grep -q '^dynamic_chain' "$config_file" || error "dynamic_chain is not active."
    if grep -q '^strict_chain' "$config_file"; then
        error "strict_chain is still active."
    fi
    grep -Eq '^proxy_dns[[:space:]]*$' "$config_file" || error "proxy_dns is not active."
    if grep -Eq '^(proxy_dns_old|proxy_dns_daemon)' "$config_file"; then
        error "proxy_dns_old/daemon is still active."
    fi
    if grep -Eq '^socks4[[:space:]]+127\.0\.0\.1' "$config_file"; then
        error "Local socks4 is still active."
    fi
    grep -Eq "^socks5[[:space:]]+${socks_host//./\\.}[[:space:]]+${socks_port}" "$config_file" \
        || error "socks5 line not found."
}

# Run the full proxychains configuration
config_mode() {
    detect_config
    info "Configuring: ${underline}${config_file}${reset}${white}"
    check_permission
    apply_config
    verify_result
    printf '%s%s%s\n' "${bold}${green}" "Proxychains configuration completed successfully!" "$reset"
    info "Test: proxychains4 curl ifconfig.me"
}

######################################################################
#-------------------------- TOR (-t / -r) ---------------------------#
######################################################################

# Stop Tor, delete temporary files and restore the terminal cursor
cleanup() {
    trap - EXIT INT TERM
    printf '%s' "$cursor_on"

    if [ -n "$sleep_pid" ]; then
        kill "$sleep_pid" 2>/dev/null
    fi

    if [ -n "$tor_pid" ] && kill -0 "$tor_pid" 2>/dev/null; then
        info "Stopping the Tor connection..."
        kill "$tor_pid" 2>/dev/null
        wait "$tor_pid" 2>/dev/null
    fi

    if [ -n "$tor_log" ]; then
        rm -f "$tor_log"
    fi

    if [ -n "$datadir" ]; then
        rm -rf "$datadir"
    fi
}

# Check whether a local port is already in use by another process
port_in_use() {
    ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null
}

# Warn and exit if the ports Tor needs are already taken
check_ports() {
    if port_in_use "$socks_port"; then
        error "Port ${socks_port} is already in use (probably the system Tor). Stop it first: sudo systemctl stop tor"
    fi
    if [ "$interval" -gt 0 ] && port_in_use "$ctrl_port"; then
        error "Control port ${ctrl_port} is already in use. Stop the other Tor first."
    fi
}

# Start Tor in the background (with a control port in -r mode)
start_tor() {
    local options=()
    tor_log=$(mktemp)

    if [ "$interval" -gt 0 ]; then
        datadir=$(mktemp -d)
        options=(--DataDirectory "$datadir" --ControlPort "127.0.0.1:${ctrl_port}" --CookieAuthentication 1)
    fi

    tor ${options[@]+"${options[@]}"} > "$tor_log" 2>&1 &
    tor_pid=$!
    info "Starting Tor connection..."
}

# Follow Tor's bootstrap until 100% or until the timeout is reached
wait_for_connection() {
    local elapsed=0 progress="" previous=""
    while [ "$elapsed" -lt "$timeout_secs" ]; do
        if ! kill -0 "$tor_pid" 2>/dev/null; then
            tail -n 5 "$tor_log" >&2
            error "Tor exited unexpectedly."
        fi

        progress=$(grep -oE 'Bootstrapped [0-9]{1,3}%' "$tor_log" | tail -n1 | grep -oE '[0-9]{1,3}')
        if [ "$progress" = "100" ]; then
            success "Tor connection established (100%)"
            return 0
        fi

        if [ -n "$progress" ] && [ "$progress" != "$previous" ]; then
            info "Progress: ${progress}%"
            previous="$progress"
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    tail -n 5 "$tor_log" >&2
    error "Timeout of ${timeout_secs}s reached without connecting to Tor."
}

# Query the current Tor exit IP, retrying on failure
query_ip() {
    local ip="" attempt
    for attempt in 1 2 3; do
        sleep 2
        ip=$(curl -s --max-time 15 --socks5-hostname "${socks_host}:${socks_port}" \
             https://check.torproject.org/api/ip | grep -oE '"IP":"[^"]+"' | cut -d'"' -f4)
        [ -n "$ip" ] && break
    done
    printf '%s' "$ip"
}

# Ask Tor for new circuits (NEWNYM) and show the new IP
change_ip() {
    local cookie ip ok=0 line
    cookie=$(od -An -v -tx1 "$datadir/control_auth_cookie" 2>/dev/null | tr -d ' \n')
    [ -n "$cookie" ] || return 1

    { exec 3<>"/dev/tcp/127.0.0.1/${ctrl_port}"; } 2>/dev/null || return 1
    printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$cookie" >&3

    while IFS= read -r -t 5 line <&3; do
        case "$line" in
            "250 OK"*) ok=$((ok + 1)) ;;
            "250 closing"*|"5"*) break ;;
        esac
    done
    exec 3>&-
    [ "$ok" -ge 2 ] || return 1

    ip=$(query_ip)
    printf 'New Tor IP: %s\n' "${ip:-unavailable}"
}

# Show the proxychains test hint
show_hint() {
    info "Test in another terminal:"
    printf '%sproxychains4 curl -s https://check.torproject.org/api/ip%s\n' "$highlight" "$reset"
}

# Clear the screen and change IP every interval until Tor exits
rotation_loop() {
    local n=0
    sleep 3; clear
    printf '%s%s%s\n' "${bold}${white}" "Changing IP every ${interval}s. Press Ctrl+C to stop." "$reset"
    show_hint
    printf '\n'

    while kill -0 "$tor_pid" 2>/dev/null; do
        sleep "$interval" & sleep_pid=$!
        wait "$sleep_pid" 2>/dev/null
        kill -0 "$tor_pid" 2>/dev/null || break

        n=$((n + 1))
        change_ip || info "Change ${n} at $(date +%H:%M:%S): failed to talk to Tor."
    done
}

# Validate the IP change interval (integer, minimum 10 seconds)
validate_interval() {
    case "$1" in
        ""|*[!0-9]*) error "Invalid interval: $1 (use a number of seconds)." ;;
    esac
    [ "$1" -ge 10 ] || error "Minimum interval is 10 seconds (Tor limit for switching circuits)."
}

# Start Tor, wait for the connection and keep the script running
tor_mode() {
    interval="${1:-0}"
    clear
    check_ports
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '%s' "$cursor_off"

    start_tor
    wait_for_connection

    success "Tor is running. Press ${bold}Ctrl+C${reset}${green} to stop."
    printf '\n'

    if [ "$interval" -gt 0 ]; then
        rotation_loop
    else
        show_hint
        wait "$tor_pid"
    fi

    info "Tor has stopped."
}

######################################################################
#------------------------------- MAIN -------------------------------#
######################################################################

# Parse the given option and call the matching mode
main() {
    case "${1:-}" in
        -c)
            check_dependencies proxychains4 sed grep tail
            config_mode
            ;;
        -t)
            check_dependencies tor mktemp grep tail
            tor_mode 0
            ;;
        -r)
            validate_interval "${2:-60}"
            check_dependencies tor curl od tr cut mktemp grep tail
            tor_mode "${2:-60}"
            ;;
        -h|"")
            usage
            ;;
        *)
            printf '%sInvalid option: %s%s\n\n' "$red" "$1" "$reset" >&2
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
