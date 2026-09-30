#!/usr/bin/env bash
# Restart a service with a retry budget.
#
# Every attempt is written to $STATE_DIR/restarts_<svc> as an epoch
# timestamp. Only attempts inside RESTART_WINDOW_SEC are counted, so a
# service that keeps dying gets at most MAX_RESTART_ATTEMPTS restarts
# per window and then we stop and page a human.

attempts_file() {
    echo "$STATE_DIR/restarts_$1"
}

# prints the number of attempts inside the window and drops older ones
recent_attempts() {
    local file now
    file="$(attempts_file "$1")"
    now="$(date +%s)"
    [[ -f "$file" ]] || { echo 0; return; }

    awk -v min=$((now - RESTART_WINDOW_SEC)) '$1 >= min' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
    wc -l < "$file"
}

heal_service() {
    local svc="$1" done_before attempt last_log started
    done_before="$(recent_attempts "$svc")"

    if (( done_before >= MAX_RESTART_ATTEMPTS )); then
        log_event "$svc" CRITICAL \
            "restart limit reached ($done_before/$MAX_RESTART_ATTEMPTS in ${RESTART_WINDOW_SEC}s), manual action needed" \
            "none"
        return 1
    fi

    attempt=$((done_before + 1))
    date +%s >> "$(attempts_file "$svc")"

    echo "restarting $svc (attempt $attempt/$MAX_RESTART_ATTEMPTS)"
    started="$(date +%s)"
    systemctl restart "$svc" 2>/dev/null
    sleep "$RESTART_WAIT_SEC"

    if verify_service "$svc"; then
        log_event "$svc" RECOVERED "service restarted (attempt $attempt/$MAX_RESTART_ATTEMPTS)" \
            "systemctl restart $svc"
        return 0
    fi

    last_log="$(journal_hint "$svc" "$started")"
    log_event "$svc" CRITICAL \
        "restart failed (attempt $attempt/$MAX_RESTART_ATTEMPTS): $VERIFY_ERR; journal: $last_log" \
        "systemctl restart $svc"
    return 1
}
