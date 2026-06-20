#!/usr/bin/env bash
# ============================================================================
# network_check.sh — Test connectivity against a list of hosts.
#
# Checks:
#   - DNS resolution (host -t A or dig)
#   - ICMP ping (1 packet, 2s timeout)
#   - TCP port connectivity via /dev/tcp or nc/nmap
#
# Usage:
#   ./network_check.sh                    # uses built-in host list
#   ./network_check.sh --hosts list.txt   # one host:port per line
#   ./network_check.sh --hosts list.txt --ping-only
#   ./network_check.sh --hosts list.txt --tcp-timeout 3
#   ./network_check.sh --hosts list.txt --json-output
# ============================================================================

set -euo pipefail

# ---- defaults ---------------------------------------------------------------
HOSTS_FILE=""
declare -a HOSTS=(
    "google.com:443"
    "github.com:443"
    "cloudflare.com:443"
    "8.8.8.8:53"
    "1.1.1.1:443"
)
PING_ONLY=false
TCP_TIMEOUT=3
JSON_OUTPUT=false
VERBOSE=false
# num pings; some platforms (macOS) need count= not -c
PING_COUNT=1
PING_TIMEOUT=2          # seconds

# ---- helpers ----------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Test network connectivity against a list of hosts (DNS, ping, TCP ports).

Options:
  --hosts FILE          Read hosts from FILE (one 'host[:port]' per line)
  --ping-only           Only perform ICMP ping tests (skip TCP)
  --tcp-timeout N       TCP connection timeout in seconds (default: 3)
  --json-output         Print results as JSON
  --verbose, -v         Print detailed progress
  --help, -h            Show this help and exit

Examples:
  ./network_check.sh
  ./network_check.sh --hosts targets.txt --json-output
  ./network_check.sh --hosts myhosts.txt --ping-only --verbose
  echo "api.example.com:8443" > hosts.txt && ./network_check.sh --hosts hosts.txt
EOF
    exit 0
}

log_msg() {
    echo "[$(date '+%H:%M:%S')] $*"
}

# ---- parse args ------------------------------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage ;;
        --hosts) shift; HOSTS_FILE="$1"; shift ;;
        --ping-only) PING_ONLY=true; shift ;;
        --tcp-timeout) shift; TCP_TIMEOUT="$1"; shift ;;
        --json-output) JSON_OUTPUT=true; shift ;;
        --verbose|-v) VERBOSE=true; shift ;;
        --*) echo "Unknown option: $1"; usage ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

# If --hosts file given, load it
if [[ -n "$HOSTS_FILE" ]]; then
    if [[ ! -f "$HOSTS_FILE" ]]; then
        echo "ERROR: hosts file not found: $HOSTS_FILE"
        exit 1
    fi
    HOSTS=()
    while IFS= read -r line; do
        line="${line%%#*}"       # strip comments
        line="$(echo "$line" | xargs)"  # trim
        [[ -z "$line" ]] && continue
        HOSTS+=("$line")
    done < "$HOSTS_FILE"
fi

# ---- detection tools --------------------------------------------------------
HAS_DIG=false
command -v dig &>/dev/null && HAS_DIG=true

HAS_HOST=false
command -v host &>/dev/null && HAS_HOST=true

HAS_NC=false
command -v nc &>/dev/null && HAS_NC=true

HAS_NMAP=false
command -v nmap &>/dev/null && HAS_NMAP=true

# ---- functions --------------------------------------------------------------

check_dns() {
    local host="$1"
    local result="fail"
    local resolved=""

    if $HAS_DIG; then
        resolved="$(dig +short "$host" A 2>/dev/null | head -1)"
        [[ -n "$resolved" ]] && result="ok"
    elif $HAS_HOST; then
        resolved="$(host -t A "$host" 2>/dev/null | grep 'has address' | head -1 | awk '{print $NF}')"
        [[ -n "$resolved" ]] && result="ok"
    else
        # fallback: getent or python
        if command -v getent &>/dev/null; then
            resolved="$(getent ahosts "$host" 2>/dev/null | head -1 | awk '{print $1}')"
        elif command -v python3 &>/dev/null; then
            resolved="$(python3 -c "import socket; print(socket.gethostbyname('$host'))" 2>/dev/null || true)"
        fi
        [[ -n "$resolved" ]] && result="ok"
    fi

    echo "$result|$resolved"
}


check_ping() {
    local host="$1"
    local result="fail"
    local rtt=""

    # Extract IP address if we can; ping by hostname works too, but
    # using resolved IP avoids extra DNS on every ping.
    local target="$host"
    local resolved
    resolved="$(echo "$2" | cut -d'|' -f2)"  # pass dns result in arg2
    [[ -n "$resolved" ]] && target="$resolved"

    # platform-adaptive ping
    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" &>/dev/null; then
        result="ok"
        # Extract RTT
        rtt="$(ping -c 1 -W "$PING_TIMEOUT" "$target" 2>/dev/null | tail -1 | grep -oP 'time=\K[0-9.]+' || true)"
    fi

    echo "$result|$rtt"
}


check_tcp() {
    local host="$1"
    local port="$2"
    local result="fail"

    # bash built-in /dev/tcp
    if (echo > "/dev/tcp/$host/$port") 2>/dev/null; then
        echo "ok"
        return
    fi

    # nc
    if $HAS_NC; then
        if nc -z -w "$TCP_TIMEOUT" "$host" "$port" 2>/dev/null; then
            echo "ok"
            return
        fi
    fi

    # nmap
    if $HAS_NMAP; then
        local nmap_out
        nmap_out="$(nmap -p "$port" --host-timeout="${TCP_TIMEOUT}s" "$host" 2>/dev/null || true)"
        if echo "$nmap_out" | grep -qE "^$port/tcp\s+open"; then
            echo "ok"
            return
        fi
    fi

    echo "fail"
}

# ---- main -------------------------------------------------------------------

declare -a RESULTS=()

$VERBOSE && log_msg "Testing ${#HOSTS[@]} host(s)…"

for entry in "${HOSTS[@]}"; do
    # Split host:port
    host="${entry%%:*}"
    port="${entry#*:}"
    if [[ "$port" == "$host" ]]; then
        port=""
    fi

    $VERBOSE && log_msg "--- $host${port:+:$port} ---"

    # DNS
    IFS='|' read -r dns_status dns_ip <<< "$(check_dns "$host")"
    $VERBOSE && log_msg "  DNS: $dns_status ($dns_ip)"

    # Ping
    IFS='|' read -r ping_status ping_rtt <<< "$(check_ping "$host" "$dns_status|$dns_ip")"
    $VERBOSE && log_msg "  Ping: $ping_status${ping_rtt:+ (${ping_rtt}ms)}"

    # TCP
    tcp_status="skip"
    if [[ -n "$port" ]] && ! $PING_ONLY; then
        tcp_status="$(check_tcp "$host" "$port")"
        $VERBOSE && log_msg "  TCP/$port: $tcp_status"
    fi

    RESULTS+=("$(cat <<EOF
{"host":"$host","port":"${port:-null}","dns":"$dns_status","ip":"$dns_ip","ping":"$ping_status","rtt":"$ping_rtt","tcp":"$tcp_status"}
EOF
    )")
done

# ---- output -----------------------------------------------------------------
if $JSON_OUTPUT; then
    echo "["
    local i=0
    for r in "${RESULTS[@]}"; do
        i=$((i+1))
        echo -n "$r"
        [[ $i -lt ${#RESULTS[@]} ]] && echo ","
    done
    echo "]"
else
    printf "%-25s %-6s %-16s %-8s %-8s %s\n" "HOST" "PORT" "DNS" "PING" "RTT(ms)" "TCP"
    printf "%-25s %-6s %-16s %-8s %-8s %s\n" "----" "----" "---" "----" "------" "---"
    for r in "${RESULTS[@]}"; do
        host=$(echo "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['host'])")
        port=$(echo "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['port'])" 2>/dev/null)
        dns=$(echo "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['dns'])")
        ip=$(echo "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['ip'])")
        ping=$(echo "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['ping'])")
        rtt=$(echo "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('rtt','') or '')")
        tcp=$(echo "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['tcp'])")
        printf "%-25s %-6s %-16s %-8s %-8s %s\n" "$host" "$port" "$dns/$ip" "$ping" "$rtt" "$tcp"
    done
fi

# Summary
ok_count=0
total=${#RESULTS[@]}
for r in "${RESULTS[@]}"; do
    ping=$(echo "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['ping'])")
    [[ "$ping" == "ok" ]] && ok_count=$((ok_count+1))
done

$VERBOSE || log_msg "Done — $ok_count/$total hosts reachable via ping."
