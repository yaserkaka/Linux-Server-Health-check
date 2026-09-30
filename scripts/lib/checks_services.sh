#!/usr/bin/env bash
# systemd service checks + failed unit report.

unit_state() {
    local state
    state="$(systemctl is-active "$1" 2>/dev/null)"
    echo "${state:-unknown}"
}

# Most useful recent journal line for a unit. systemd's own
# "Failed to start ..." lines say nothing about the cause, skip them.
# journal_hint <unit> [since_epoch]
journal_hint() {
    local logs line
    local -a since=()
    [[ -n "${2:-}" ]] && since=(--since "@$2")
    logs="$(journalctl -u "$1" "${since[@]}" -n 15 --no-pager -o cat 2>/dev/null \
            | grep -vE '^(Failed to start|Started|Starting|Stopped|Stopping)|\.service: ')"
    line="$(grep -iE 'emerg|crit|error' <<< "$logs" | tail -n1)"
    [[ -z "$line" ]] && line="$(grep -iE 'fail|denied|refused|no such' <<< "$logs" | tail -n1)"
    [[ -z "$line" ]] && line="$(journalctl -u "$1" "${since[@]}" -n 1 --no-pager -o cat 2>/dev/null)"
    echo "${line:-n/a}"
}

unit_exists() {
    systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q .
}

# Extra health test on top of "is-active". Sets VERIFY_ERR on failure.
verify_service() {
    local svc="$1" code
    VERIFY_ERR=""

    if ! systemctl is-active --quiet "$svc"; then
        VERIFY_ERR="$svc is $(unit_state "$svc")"
        return 1
    fi

    case "$svc" in
        nginx)
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$NET_TIMEOUT" "$HTTP_URL")"
            if [[ "$code" == "000" ]] || (( code >= 400 )); then
                VERIFY_ERR="nginx active but $HTTP_URL returned $code"
                return 1
            fi
            ;;
        docker)
            # the daemon can be "active" and still hang
            if ! timeout 15 docker info >/dev/null 2>&1; then
                VERIFY_ERR="docker active but 'docker info' failed"
                return 1
            fi
            ;;
    esac
    return 0
}

# Ubuntu 22.10+ uses ssh.socket by default, so ssh.service being
# inactive is normal until someone connects.
check_ssh() {
    if systemctl is-active --quiet ssh; then
        log_event ssh OK "ssh.service active"
    elif systemctl is-active --quiet ssh.socket; then
        log_event ssh OK "ssh.socket active (socket activation)"
    else
        log_event ssh CRITICAL "neither ssh.service nor ssh.socket is active"
        if in_list ssh "$SELF_HEAL_SERVICES" && (( ! NO_HEAL )); then
            heal_service ssh
        fi
    fi
}

check_service() {
    local svc="$1"

    if ! unit_exists "$svc"; then
        log_event "$svc" CRITICAL "$svc.service is not installed"
        return
    fi

    if verify_service "$svc"; then
        log_event "$svc" OK "$svc is active"
        return
    fi

    log_event "$svc" CRITICAL "$VERIFY_ERR"

    if in_list "$svc" "$SELF_HEAL_SERVICES"; then
        if (( NO_HEAL )); then
            echo "self-heal disabled (--no-heal), not touching $svc"
        else
            heal_service "$svc"
        fi
    fi
}

check_services() {
    local svc

    # /run/systemd/system only exists when systemd is PID 1
    if [[ ! -d /run/systemd/system ]]; then
        log_event systemd CRITICAL "systemd is not running (container or chroot?), service checks skipped"
        return
    fi

    for svc in $SERVICES; do
        if [[ "$svc" == "ssh" ]]; then
            check_ssh
        else
            check_service "$svc"
        fi
    done
}

check_failed_units() {
    local unit last found=0
    [[ -d /run/systemd/system ]] || return
    while read -r unit _; do
        [[ -z "$unit" ]] && continue
        in_list "$unit" "$FAILED_UNITS_IGNORE" && continue
        # already reported (and maybe healed) by check_service
        in_list "${unit%.service}" "$SERVICES" && continue
        found=1
        last="$(journal_hint "$unit")"
        log_event failed_units CRITICAL "$unit failed; journal: $last"
    done < <(systemctl --failed --no-legend --plain --type=service 2>/dev/null)

    (( found )) || log_event failed_units OK "no failed services"
}
