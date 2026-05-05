#!/bin/bash

# Complete network management script for Proxmox CT
# Supports unlimited internal bridges
# Usage: ./mynatrules.sh <action> [options]

EXTERNAL_INTERFACE="vmbr0"
CONFIG_FILE="/etc/nft-manager.conf"

# ─────────────────────────────────────────────
# Configuration management
# Format: BRIDGE_vmbr1="192.168.1.0/24"
#         BRIDGE_vmbr2="192.168.5.0/24"
# ─────────────────────────────────────────────

function load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "⚠ No configuration found. Use '$0 add-bridge <iface> <cidr>' to add a bridge."
        exit 1
    fi
    source "$CONFIG_FILE"
}

function save_config() {
    {
        echo "# nft-manager configuration — generated on $(date)"
        compgen -v | grep '^BRIDGE_' | while read -r var; do
            echo "${var}=\"${!var}\""
        done
    } > "$CONFIG_FILE"
}

function get_all_bridges() {
    compgen -v | grep '^BRIDGE_' | sed 's/^BRIDGE_//'
}

function get_bridge_cidr() {
    local IFACE=$1
    local VAR="BRIDGE_${IFACE}"
    echo "${!VAR}"
}

# ─────────────────────────────────────────────
# CIDR overlap detection
# ─────────────────────────────────────────────

# Convert an IP string to a 32-bit integer
function ip_to_int() {
    local IP=$1
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$IP"
    echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
}

# Return the network address of a CIDR as an integer
function cidr_network_int() {
    local CIDR=$1
    local IP="${CIDR%/*}"
    local MASK="${CIDR#*/}"
    local IP_INT
    IP_INT=$(ip_to_int "$IP")
    local MASK_INT=$(( 0xFFFFFFFF << (32 - MASK) & 0xFFFFFFFF ))
    echo $(( IP_INT & MASK_INT ))
}

# Return the broadcast address of a CIDR as an integer
function cidr_broadcast_int() {
    local CIDR=$1
    local MASK="${CIDR#*/}"
    local NET_INT
    NET_INT=$(cidr_network_int "$CIDR")
    local WILDCARD=$(( (1 << (32 - MASK)) - 1 ))
    echo $(( NET_INT | WILDCARD ))
}

# Check if two CIDRs overlap — returns 0 (true) if they do
function cidrs_overlap() {
    local A=$1
    local B=$2
    local A_NET A_BRD B_NET B_BRD
    A_NET=$(cidr_network_int "$A")
    A_BRD=$(cidr_broadcast_int "$A")
    B_NET=$(cidr_network_int "$B")
    B_BRD=$(cidr_broadcast_int "$B")
    if (( A_NET <= B_BRD && B_NET <= A_BRD )); then
        return 0
    fi
    return 1
}

# Check new CIDR against all registered bridges — exits if conflict found
function check_cidr_conflicts() {
    local NEW_CIDR=$1
    local NEW_IFACE=$2
    local CONFLICT=0
    local BRIDGES
    BRIDGES=$(get_all_bridges)
    [ -z "$BRIDGES" ] && return 0

    while IFS= read -r EXISTING_IFACE; do
        [ "$EXISTING_IFACE" = "$NEW_IFACE" ] && continue
        local EXISTING_CIDR
        EXISTING_CIDR=$(get_bridge_cidr "$EXISTING_IFACE")
        if cidrs_overlap "$NEW_CIDR" "$EXISTING_CIDR"; then
            echo "✗ Network conflict detected:"
            echo "    New bridge     : ${NEW_IFACE} → ${NEW_CIDR}"
            echo "    Existing bridge: ${EXISTING_IFACE} → ${EXISTING_CIDR}"
            echo "  These two networks overlap. Please use non-overlapping ranges."
            CONFLICT=1
        fi
    done <<< "$BRIDGES"

    [ "$CONFLICT" -eq 1 ] && exit 1
}

# ─────────────────────────────────────────────
# Bridge management
# ─────────────────────────────────────────────

function add_bridge() {
    local IFACE=$1
    local CIDR=$2

    if [ -z "$IFACE" ] || [ -z "$CIDR" ]; then
        echo "✗ Usage: $0 add-bridge <interface> <cidr>"
        echo "  Example: $0 add-bridge vmbr1 192.168.1.0/24"
        exit 1
    fi

    if ! echo "$CIDR" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
        echo "✗ Invalid CIDR format. Expected: X.X.X.X/mask (e.g.: 192.168.1.0/24)"
        exit 1
    fi

    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

    # Check for overlaps with already registered bridges
    check_cidr_conflicts "$CIDR" "$IFACE"

    local VAR="BRIDGE_${IFACE}"
    declare -g "${VAR}=${CIDR}"

    save_config

    echo ""
    echo "=== Adding bridge ${IFACE} (${CIDR}) ==="
    echo ""

    setup_base_tables

    echo "Enabling IP forwarding..."
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "✓ IP forwarding enabled"

    echo "Configuring masquerading for ${CIDR}..."
    if ! nft list chain ip nat postrouting 2>/dev/null | grep -q "ip saddr ${CIDR} masquerade"; then
        nft add rule ip nat postrouting oifname "${EXTERNAL_INTERFACE}" ip saddr "${CIDR}" masquerade
        echo "✓ Masquerading configured"
    else
        echo "  (masquerade rule already exists, skipped)"
    fi

    echo "Configuring forwarding for ${IFACE}..."
    if ! nft list chain ip filter forward 2>/dev/null | grep -q "iifname \"${IFACE}\""; then
        nft add rule ip filter forward iifname "${IFACE}" oifname "${EXTERNAL_INTERFACE}" accept
        nft add rule ip filter forward iifname "${EXTERNAL_INTERFACE}" oifname "${IFACE}" ct state related,established accept
        echo "✓ Forwarding configured"
    else
        echo "  (forwarding rules already exist, skipped)"
    fi

    nft add rule ip filter input ct state established,related accept 2>/dev/null
    nft add rule ip filter input iifname "lo" accept 2>/dev/null

    save_nft_config

    echo ""
    echo "✓ Bridge ${IFACE} (${CIDR}) registered and configured"
    echo ""
}

function del_bridge() {
    local IFACE=$1

    if [ -z "$IFACE" ]; then
        echo "✗ Usage: $0 del-bridge <interface>"
        exit 1
    fi

    load_config

    local CIDR
    CIDR=$(get_bridge_cidr "$IFACE")
    if [ -z "$CIDR" ]; then
        echo "✗ Bridge ${IFACE} not found in configuration."
        exit 1
    fi

    echo ""
    echo "=== Removing bridge ${IFACE} (${CIDR}) ==="
    echo ""

    echo "Removing masquerade rule for ${CIDR}..."
    local HANDLE
    HANDLE=$(nft -a list chain ip nat postrouting 2>/dev/null | grep "ip saddr ${CIDR} masquerade" | grep -oP 'handle \K\d+' | head -1)
    if [ -n "$HANDLE" ]; then
        nft delete rule ip nat postrouting handle "$HANDLE"
        echo "✓ Masquerade rule removed"
    else
        echo "  (no masquerade rule found)"
    fi

    echo "Removing forwarding rules for ${IFACE}..."
    while true; do
        HANDLE=$(nft -a list chain ip filter forward 2>/dev/null | grep "\"${IFACE}\"" | grep -oP 'handle \K\d+' | head -1)
        [ -z "$HANDLE" ] && break
        nft delete rule ip filter forward handle "$HANDLE"
    done
    echo "✓ Forwarding rules removed"

    local VAR="BRIDGE_${IFACE}"
    unset "$VAR"
    save_config

    save_nft_config

    echo ""
    echo "✓ Bridge ${IFACE} removed"
    echo ""
}

# ─────────────────────────────────────────────
# Internet access — apply all bridges
# ─────────────────────────────────────────────

function setup_internet_access() {
    load_config

    local BRIDGES
    BRIDGES=$(get_all_bridges)

    if [ -z "$BRIDGES" ]; then
        echo "⚠ No bridges configured. Use '$0 add-bridge <iface> <cidr>' first."
        exit 1
    fi

    echo ""
    echo "=== Internet access configuration ==="
    echo "  Ext. interface : ${EXTERNAL_INTERFACE}"
    echo ""

    echo "[1/3] Enabling IP forwarding..."
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "✓ IP forwarding enabled"

    echo ""
    echo "[2/3] Configuring nftables tables..."
    setup_base_tables

    echo ""
    echo "[3/3] Applying rules for all bridges..."
    nft flush chain ip nat postrouting
    nft flush chain ip filter forward

    while IFS= read -r IFACE; do
        local CIDR
        CIDR=$(get_bridge_cidr "$IFACE")
        echo ""
        echo "  Bridge ${IFACE} → ${CIDR}"
        nft add rule ip nat postrouting oifname "${EXTERNAL_INTERFACE}" ip saddr "${CIDR}" masquerade
        nft add rule ip filter forward iifname "${IFACE}" oifname "${EXTERNAL_INTERFACE}" accept
        nft add rule ip filter forward iifname "${EXTERNAL_INTERFACE}" oifname "${IFACE}" ct state related,established accept
        echo "  ✓ Masquerading and forwarding configured"
    done <<< "$BRIDGES"

    nft add rule ip filter input ct state established,related accept 2>/dev/null
    nft add rule ip filter input iifname "lo" accept 2>/dev/null
    echo ""
    echo "✓ Base filtering rules added"

    save_nft_config
    echo ""
    echo "✓ Internet access configured for all bridges"
    echo ""
}

# ─────────────────────────────────────────────
# nftables base tables
# ─────────────────────────────────────────────

function setup_base_tables() {
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; policy accept \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; policy accept \; } 2>/dev/null
    nft add table ip filter 2>/dev/null
    nft add chain ip filter input { type filter hook input priority 0 \; policy accept \; } 2>/dev/null
    nft add chain ip filter forward { type filter hook forward priority 0 \; policy accept \; } 2>/dev/null
    echo "✓ Tables and chains ready"
}

# ─────────────────────────────────────────────
# External port calculation
# Format: <3rd byte> + <last 2 digits of port> + <last 2 digits of 4th byte>
# ─────────────────────────────────────────────



function calc_external_port() {
    local PORT=$1
    local CT_IP=$2
    IFS='.' read -r o1 o2 o3 o4 <<< "$CT_IP"
    
    # 80 -> service code 80, 443 -> service code 81
    local SERVICE_CODE
    if [ "$PORT" = "443" ]; then
        SERVICE_CODE=81
    else
        SERVICE_CODE=$PORT
    fi
    
    local SERVICE_DIGITS
    SERVICE_DIGITS=$(printf "%02d" $((SERVICE_CODE % 100)))
    local IP_DIGITS
    IP_DIGITS=$(printf "%02d" $((o4 % 100)))
    echo "${o3}${SERVICE_DIGITS}${IP_DIGITS}"
}


# ─────────────────────────────────────────────
# CT port management
# ─────────────────────────────────────────────

function add_ct_ports() {
    local CT_IP=$1
    shift

    setup_base_tables > /dev/null

    echo ""
    echo "=== Adding ports for CT ${CT_IP} ==="
    echo ""

    for PORT in "$@"; do
        local EXTERNAL_PORT
        EXTERNAL_PORT=$(calc_external_port "$PORT" "$CT_IP")
        echo "Configuring port ${PORT} → ${EXTERNAL_PORT}..."
        nft add rule ip nat prerouting tcp dport "${EXTERNAL_PORT}" dnat to "${CT_IP}:${PORT}"
        nft add rule ip filter input tcp dport "${EXTERNAL_PORT}" accept
        echo "✓ ${EXTERNAL_PORT} → ${CT_IP}:${PORT}"
    done

    save_nft_config
    echo ""
    echo "✓ CT ${CT_IP} configured"
    echo ""
}

function del_ct_ports() {
    local CT_IP=$1
    shift

    echo ""
    echo "=== Removing ports for CT ${CT_IP} ==="
    echo ""

    for PORT in "$@"; do
        local EXTERNAL_PORT
        EXTERNAL_PORT=$(calc_external_port "$PORT" "$CT_IP")
        echo "Removing port ${EXTERNAL_PORT}..."

        local HANDLE
        HANDLE=$(nft -a list chain ip nat prerouting 2>/dev/null | grep "tcp dport ${EXTERNAL_PORT}" | grep -oP 'handle \K\d+' | head -1)
        if [ -n "$HANDLE" ]; then
            nft delete rule ip nat prerouting handle "$HANDLE"
            echo "✓ NAT rule removed"
        fi

        HANDLE=$(nft -a list chain ip filter input 2>/dev/null | grep "tcp dport ${EXTERNAL_PORT}" | grep -oP 'handle \K\d+' | head -1)
        if [ -n "$HANDLE" ]; then
            nft delete rule ip filter input handle "$HANDLE"
            echo "✓ Input rule removed"
        fi
    done

    save_nft_config
    echo ""
}

# ─────────────────────────────────────────────
# Display / reset
# ─────────────────────────────────────────────

function show_rules() {
    echo ""
    echo "=== REGISTERED BRIDGES ==="
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        local BRIDGES
        BRIDGES=$(get_all_bridges)
        if [ -z "$BRIDGES" ]; then
            echo "  No bridges configured."
        else
            while IFS= read -r IFACE; do
                echo "  ${IFACE} → $(get_bridge_cidr "$IFACE")"
            done <<< "$BRIDGES"
        fi
    else
        echo "  No configuration file found."
    fi
    echo "  Ext. interface : ${EXTERNAL_INTERFACE}"
    echo ""

    echo "=== NAT RULES (Port forwarding) ==="
    nft list chain ip nat prerouting 2>/dev/null || echo "No rules"
    echo ""
    echo "=== NAT RULES (Masquerading/Internet) ==="
    nft list chain ip nat postrouting 2>/dev/null || echo "No rules"
    echo ""
    echo "=== FORWARDING RULES ==="
    nft list chain ip filter forward 2>/dev/null || echo "No rules"
    echo ""
    echo "=== INPUT RULES (Allowed ports) ==="
    nft list chain ip filter input 2>/dev/null | grep -E "tcp dport|accept" || echo "No rules"
    echo ""
}

function reset_rules() {
    echo "Resetting all nftables rules..."
    nft flush ruleset
    echo "✓ All rules have been removed"
    rm -f /etc/nftables.conf
    echo "✓ NFTables configuration removed"
    echo ""
    echo "Note: $CONFIG_FILE is preserved (registered bridges kept)."
    echo "Use '$0 setup-internet' to reapply all rules."
    echo ""
}

function save_nft_config() {
    nft list ruleset > /etc/nftables.conf
    systemctl enable nftables 2>/dev/null
}

# ─────────────────────────────────────────────
# Help
# ─────────────────────────────────────────────

function show_usage() {
    echo ""
    echo "Usage: $0 <action> [options]"
    echo ""
    echo "  add-bridge <iface> <cidr>  - Register a bridge and configure it immediately"
    echo "  del-bridge <iface>         - Remove a bridge and its nftables rules"
    echo "  setup-internet             - (Re)apply all rules for all registered bridges"
    echo "  add-ct <ip> <ports...>     - Add port mappings for a CT"
    echo "  del-ct <ip> <ports...>     - Remove port mappings for a CT"
    echo "  show                       - Display registered bridges and active rules"
    echo "  reset                      - Reset all nftables rules (bridges config kept)"
    echo ""
    echo "External port calculation: <3rd IP byte> + <last 2 digits of port> + <last 2 digits of 4th byte>"
    echo "  80 and 443 share the same external port."
    echo ""
    echo "Examples:"
    echo "  $0 add-bridge vmbr1 192.168.1.0/24"
    echo "  $0 add-bridge vmbr2 192.168.5.0/24"
    echo "  $0 del-bridge vmbr2"
    echo "  $0 setup-internet"
    echo "  $0 add-ct 192.168.1.122 80 443 22 5432"
    echo "  $0 del-ct 192.168.1.122 80"
    echo "  $0 show"
    echo ""
    exit 1
}

# ─────────────────────────────────────────────
# Main program
# ─────────────────────────────────────────────

case "${1}" in
    add-bridge)
        add_bridge "$2" "$3"
        ;;
    del-bridge)
        del_bridge "$2"
        ;;
    setup-internet)
        setup_internet_access
        ;;
    add-ct)
        if [ -z "$2" ]; then
            show_usage
        fi
        add_ct_ports "$2" "${@:3}"
        ;;
    del-ct)
        if [ -z "$2" ]; then
            show_usage
        fi
        del_ct_ports "$2" "${@:3}"
        ;;
    show)
        show_rules
        ;;
    reset)
        reset_rules
        ;;
    *)
        show_usage
        ;;
esac
