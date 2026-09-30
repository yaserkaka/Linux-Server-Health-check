#!/usr/bin/env bash
# Server health check with basic self-healing.
# Normally run by server-health.timer every 5 minutes.
#
# Exit codes: 0 all ok, 1 warnings, 2 critical, 3 script error

set -uo pipefail
export LC_ALL=C   # uptime/df output must not be localized (commas vs dots)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="/etc/server-health/health.conf"
ONLY="all"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/checks_system.sh
source "$SCRIPT_DIR/lib/checks_system.sh"
# shellcheck source=lib/checks_network.sh
source "$SCRIPT_DIR/lib/checks_network.sh"
# shellcheck source=lib/checks_services.sh
source "$SCRIPT_DIR/lib/checks_services.sh"
# shellcheck source=lib/self_heal.sh
source "$SCRIPT_DIR/lib/self_heal.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  -c, --config FILE   config file (default: $CONFIG)
      --only GROUP    run one group: system | network | services
      --no-heal       detect only, never restart anything
      --no-alert      don't send external notifications
  -h, --help          show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG="$2"; shift 2 ;;
        --only)      ONLY="$2"; shift 2 ;;
        --no-heal)   NO_HEAL=1; shift ;;
        --no-alert)  NO_ALERT=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; exit 3 ;;
    esac
done

# running from a git checkout: fall back to the repo config
if [[ ! -e "$CONFIG" && -e "$SCRIPT_DIR/../config/health.conf" ]]; then
    CONFIG="$SCRIPT_DIR/../config/health.conf"
fi

load_config "$CONFIG"

if [[ $EUID -ne 0 ]]; then
    echo "note: not running as root, self-healing disabled" >&2
    NO_HEAL=1
fi

mkdir -p "$LOG_DIR" "$STATE_DIR" || die "cannot create $LOG_DIR or $STATE_DIR"

# the timer shouldn't stack runs if one hangs on a slow network check
exec 9>"$STATE_DIR/.lock"
if ! flock -n 9; then
    echo "another health check is still running, skipping"
    exit 0
fi

if [[ "$ONLY" == all || "$ONLY" == system ]]; then
    check_cpu
    check_memory
    check_disk
    check_load
fi

if [[ "$ONLY" == all || "$ONLY" == network ]]; then
    check_ip_address
    check_default_route
    check_gateway
    check_internet
    check_dns
    check_ports
    check_http
fi

if [[ "$ONLY" == all || "$ONLY" == services ]]; then
    check_services
    check_failed_units
fi

summary="ok=$OK_COUNT warning=$WARN_COUNT critical=$CRIT_COUNT"
echo "summary: $summary"

if (( CRIT_COUNT > 0 )); then
    exit 2
elif (( WARN_COUNT > 0 )); then
    exit 1
fi
exit 0
