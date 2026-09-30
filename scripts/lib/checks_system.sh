#!/usr/bin/env bash
# CPU, memory, disk and load checks.

# level_for <value> <warn> <crit>
level_for() {
    if is_float_gt "$1" "$3"; then
        echo CRITICAL
    elif is_float_gt "$1" "$2"; then
        echo WARNING
    else
        echo OK
    fi
}

# CPU usage over a 1 second sample, taken from /proc/stat.
# top/mpstat output differs between versions, /proc/stat doesn't.
check_cpu() {
    local u1 n1 s1 i1 w1 q1 sq1 st1 u2 n2 s2 i2 w2 q2 sq2 st2
    read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
    sleep 1
    read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat

    local idle=$(( (i2 + w2) - (i1 + w1) ))
    local total=$(( (u2 + n2 + s2 + i2 + w2 + q2 + sq2 + st2) - (u1 + n1 + s1 + i1 + w1 + q1 + sq1 + st1) ))
    (( total > 0 )) || total=1
    local usage=$(( (100 * (total - idle)) / total ))

    local level
    level="$(level_for "$usage" "$CPU_WARN" "$CPU_CRIT")"
    log_event cpu "$level" "cpu usage ${usage}% (warn ${CPU_WARN}%, crit ${CPU_CRIT}%)"
}

# Uses the "available" column. "used" includes page cache and makes
# every healthy server look full.
check_memory() {
    local total avail
    read -r total avail < <(free -b | awk '/^Mem:/ {print $2, $7}')
    if [[ -z "$total" || "$total" -eq 0 ]]; then
        log_event memory WARNING "could not read memory stats from free"
        return
    fi

    local used_pct=$(( (100 * (total - avail)) / total ))
    local level
    level="$(level_for "$used_pct" "$MEM_WARN" "$MEM_CRIT")"
    log_event memory "$level" "memory used ${used_pct}%, $((avail / 1024 / 1024)) MiB available"
}

check_disk() {
    local mount pct ipct level
    for mount in $DISK_MOUNTS; do
        pct="$(df -P "$mount" 2>/dev/null | awk 'NR==2 {gsub("%", "", $5); print $5}')"
        if [[ -z "$pct" ]]; then
            log_event "disk:$mount" WARNING "df returned nothing for $mount"
            continue
        fi

        level="$(level_for "$pct" "$DISK_WARN" "$DISK_CRIT")"
        log_event "disk:$mount" "$level" "$mount is ${pct}% full"

        # a disk can be "empty" and still full of inodes (lots of small files)
        ipct="$(df -Pi "$mount" 2>/dev/null | awk 'NR==2 {gsub("%", "", $5); print $5}')"
        if [[ "$ipct" =~ ^[0-9]+$ ]] && (( ipct > INODE_CRIT )); then
            log_event "inodes:$mount" CRITICAL "$mount inode usage ${ipct}%"
        fi
    done
}

check_load() {
    local cores load5 per_core level
    cores="$(nproc)"
    # "... load average: 0.52, 0.58, 0.59"
    load5="$(uptime | awk -F'load average: ' '{print $2}' | awk -F', ' '{print $2}')"

    if [[ -z "$load5" ]]; then
        log_event load WARNING "could not parse uptime output"
        return
    fi

    per_core="$(awk -v l="$load5" -v c="$cores" 'BEGIN { printf "%.2f", l / c }')"
    level="$(level_for "$per_core" "$LOAD_WARN_PER_CORE" "$LOAD_CRIT_PER_CORE")"
    log_event load "$level" "5m load $load5 on $cores cores (${per_core} per core)"
}
