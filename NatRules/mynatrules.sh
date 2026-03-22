#!/bin/bash
 
# Complete network management script for Proxmox CT
# Usage: ./nft-complete-manager.sh <action> [options]
 
EXTERNAL_INTERFACE="vmbr0"
CONFIG_FILE="/etc/nft-manager.conf"
 
# ─────────────────────────────────────────────
# Configuration management
# ─────────────────────────────────────────────
 
function load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "⚠ No configuration found. Use '$0 config' to initialize."
        exit 1
    fi
    source "$CONFIG_FILE"
    NETWORK_CIDR="${NETWORK_PREFIX}.0/${NETWORK_MASK}"
}
 
function save_config() {
    cat > "$CONFIG_FILE" <<EOF
# nft-manager configuration — generated on $(date)
NETWORK_PREFIX="${NETWORK_PREFIX}"
INTERNAL_INTERFACE="${INTERNAL_INTERFACE}"
NETWORK_MASK="${NETWORK_MASK}"
EOF
}
 
function prompt_config() {
    echo ""
    echo "=== Initial configuration ==="
    echo ""
 
    read -rp "  Network prefix (3 bytes, e.g.: 192.168.1) : " NETWORK_PREFIX
    if ! echo "$NETWORK_PREFIX" | grep -qE '^([0-9]{1,3}\.){2}[0-9]{1,3}$'; then
        echo "✗ Invalid format. Expected: X.X.X (e.g.: 192.168.1)"
        exit 1
    fi
 
    read -rp "  Network mask (e.g.: 24) [24] : " input
    NETWORK_MASK="${input:-24}"
 
    read -rp "  Internal network interface (e.g.: vmbr1) [vmbr1] : " input
    INTERNAL_INTERFACE="${input:-vmbr1}"
 
    save_config
    echo ""
    echo "✓ Configuration saved to $CONFIG_FILE"
    echo ""
}
 
# ─────────────────────────────────────────────
# External port calculation
# Format: <3rd byte> + <last 2 digits of port> + <last 2 digits of 4th byte>
# ─────────────────────────────────────────────
 
function calc_external_port() {
    local PORT=$1
    local CT_IP=$2
 
    IFS='.' read -r o1 o2 o3 o4 <<< "$CT_IP"
 
    # 80 and 443 share the same service code: 80
    [ "$PORT" = "443" ] && PORT=80
 
    local SERVICE_DIGITS=$(printf "%02d" $((PORT % 100)))
    local IP_DIGITS=$(printf "%02d" $((o4 % 100)))
 
    echo "${o3}${SERVICE_DIGITS}${IP_DIGITS}"
}
 
# ─────────────────────────────────────────────
# nftables tables
# ─────────────────────────────────────────────
 
function setup_base_tables() {
    echo "Creating base tables and chains..."
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; policy accept \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; policy accept \; } 2>/dev/null
    nft add table ip filter 2>/dev/null
    nft add chain ip filter input { type filter hook input priority 0 \; policy accept \; } 2>/dev/null
    nft add chain ip filter forward { type filter hook forward priority 0 \; policy accept \; } 2>/dev/null
    echo "✓ Tables and chains created"
}
 
function setup_internet_access() {
    load_config
    echo ""
    echo "=== Internet access configuration ==="
    echo ""
    echo "  Network        : ${NETWORK_CIDR}"
    echo "  Int. interface : ${INTERNAL_INTERFACE}"
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
    echo "[3/3] Adding Internet access rules..."
    nft flush chain ip nat postrouting
    nft add rule ip nat postrouting oifname \"${EXTERNAL_INTERFACE}\" ip saddr ${NETWORK_CIDR} masquerade
    echo "✓ Masquerading configured"
    nft add rule ip filter forward iifname \"${INTERNAL_INTERFACE}\" oifname \"${EXTERNAL_INTERFACE}\" accept 2>/dev/null
    nft add rule ip filter forward iifname \"${EXTERNAL_INTERFACE}\" oifname \"${INTERNAL_INTERFACE}\" ct state related,established accept 2>/dev/null
    echo "✓ Forwarding configured"
    nft add rule ip filter input ct state established,related accept 2>/dev/null
    nft add rule ip filter input iifname "lo" accept 2>/dev/null
    echo "✓ Base filtering rules added"
 
    save_nft_config
    echo ""
    echo "✓ Internet access configured for ${NETWORK_CIDR}"
    echo ""
}
 
# ─────────────────────────────────────────────
# CT port management
# ─────────────────────────────────────────────
 
function add_ct_ports() {
    local CT_IP=$1
    shift
 
    echo ""
    echo "=== Adding ports for CT ${CT_IP} ==="
    echo ""
 
    for PORT in "$@"; do
        local EXTERNAL_PORT
        EXTERNAL_PORT=$(calc_external_port "$PORT" "$CT_IP")
        echo "Configuring port ${PORT} → ${EXTERNAL_PORT}..."
        nft add rule ip nat prerouting tcp dport ${EXTERNAL_PORT} dnat to ${CT_IP}:${PORT}
        nft add rule ip filter input tcp dport ${EXTERNAL_PORT} accept
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
        HANDLE=$(nft -a list chain ip nat prerouting | grep "tcp dport ${EXTERNAL_PORT}" | grep -oP 'handle \K\d+' | head -1)
        if [ -n "$HANDLE" ]; then
            nft delete rule ip nat prerouting handle $HANDLE
            echo "✓ NAT rule removed"
        fi
 
        HANDLE=$(nft -a list chain ip filter input | grep "tcp dport ${EXTERNAL_PORT}" | grep -oP 'handle \K\d+' | head -1)
        if [ -n "$HANDLE" ]; then
            nft delete rule ip filter input handle $HANDLE
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
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo ""
        echo "=== CONFIGURATION ==="
        echo "  Network        : ${NETWORK_PREFIX}.0/${NETWORK_MASK}"
        echo "  Int. interface : ${INTERNAL_INTERFACE}"
        echo "  Ext. interface : ${EXTERNAL_INTERFACE}"
        echo ""
    fi
 
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
    echo "Note: $CONFIG_FILE is preserved."
    echo "Use '$0 setup-internet' to reconfigure Internet access."
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
    echo "  config                     - Configure network settings"
    echo "  setup-internet             - Configure masquerading and forwarding"
    echo "  add-ct <ip> <ports...>     - Add port mappings for a CT"
    echo "  del-ct <ip> <ports...>     - Remove port mappings for a CT"
    echo "  show                       - Display config and active rules"
    echo "  reset                      - Reset all nftables rules"
    echo ""
    echo "External port calculation: <3rd IP byte> + <last 2 digits of port> + <last 2 digits of 4th byte>"
    echo "  80 and 443 share the same external port."
    echo ""
    echo "Examples:"
    echo "  $0 config"
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
    config)
        prompt_config
        ;;
    setup-internet)
        setup_internet_access
        ;;
    add-ct)
        if [ -z "$2" ]; then
            show_usage
        fi
        setup_base_tables
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
