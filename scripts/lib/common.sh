#!/usr/bin/env bash
# Shared helpers: config loading, logging, alert hook.
# Sourced by health-check.sh - not meant to be run directly.

HOSTNAME_SHORT="$(hostname -s)"
OK_COUNT=0
WARN_COUNT=0
CRIT_COUNT=0
# shellcheck disable=SC2034  # read by checks_services.sh
NO_HEAL=0
NO_ALERT=0

die() {
    echo "ERROR: $*" >&2
    exit 3
}

have() {
    command -v "$1" >/dev/null 2>&1
}

load_config() {
    local file="$1"
    [[ -r "$file" ]] || die "config file $file not readable"

    # the file is sourced as root, refuse it if anyone can write to it
    local perms
    perms="$(stat -c '%a' "$file")"
    if (( (8#$perms & 8#022) != 0 )); then
        die "$file is group/world writable ($perms), fix permissions first"
    fi

    # shellcheck source=../../config/health.conf
    source "$file"

    local var
    for var in CPU_WARN CPU_CRIT MEM_WARN MEM_CRIT DISK_WARN DISK_CRIT INODE_CRIT \
               MAX_RESTART_ATTEMPTS RESTART_WINDOW_SEC RESTART_WAIT_SEC NET_TIMEOUT; do
        [[ "${!var:-}" =~ ^[0-9]+$ ]] || die "config: $var must be an integer (got '${!var:-}')"
    done
}

# is_float_gt 3.5 2  -> true
is_float_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

# in_list <word> "<space separated list>"
in_list() {
    local needle="$1" list="$2" item
    for item in $list; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# log_event <check> <status> <message> [recovery_action]
log_event() {
    local check="$1" status="$2" msg="$3" action="${4:--}"
    local ts line

    # pipes would break the log format
    msg="${msg//|//}"
    action="${action//|//}"

    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    line="$ts | $HOSTNAME_SHORT | $check | $status | $msg | $action"

    echo "$line"
    echo "$line" >> "$LOG_DIR/health.log"

    case "$status" in
        OK|RECOVERED) OK_COUNT=$((OK_COUNT + 1)) ;;
        WARNING)      WARN_COUNT=$((WARN_COUNT + 1)) ;;
        CRITICAL)     CRIT_COUNT=$((CRIT_COUNT + 1)) ;;
    esac

    if in_list "$status" "$ALERT_ON"; then
        send_alert "$check" "$status" "$msg" "$action"
    fi
}

send_alert() {
    [[ "$NO_ALERT" -eq 1 ]] && return 0

    local -a cmd
    read -r -a cmd <<< "$ALERT_CMD"

    if ! "${cmd[@]}" \
            --host "$HOSTNAME_SHORT" \
            --check "$1" \
            --status "$2" \
            --message "$3" \
            --action "$4" \
            --channels "$ALERT_CHANNELS" \
            --cooldown "$ALERT_COOLDOWN_SEC" \
            --state-file "$STATE_DIR/alerts.json" >>"$LOG_DIR/alerts.log" 2>&1; then
        echo "warning: alert delivery failed for $1 (see $LOG_DIR/alerts.log)" >&2
    fi
}
