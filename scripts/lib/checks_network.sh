#!/usr/bin/env bash
# Network checks, roughly in the order you'd troubleshoot by hand:
# address -> route -> gateway -> internet -> dns -> ports -> http

GATEWAY=""

check_ip_address() {
    local addrs
    addrs="$(ip -4 -o addr show scope global | awk '{printf "%s=%s ", $2, $4}')"
    if [[ -z "$addrs" ]]; then
        log_event ip_address CRITICAL "no global IPv4 address configured"
    else
        log_event ip_address OK "${addrs% }"
    fi
}

check_default_route() {
    local route dev
    route="$(ip route show default | head -n1)"
    if [[ -z "$route" ]]; then
        log_event default_route CRITICAL "no default route"
        return
    fi
    GATEWAY="$(awk '{for (i=1; i<NF; i++) if ($i == "via") print $(i+1)}' <<< "$route")"
    dev="$(awk '{for (i=1; i<NF; i++) if ($i == "dev") print $(i+1)}' <<< "$route")"
    log_event default_route OK "default via ${GATEWAY:-none} dev $dev"
}

check_gateway() {
    if [[ -z "$GATEWAY" ]]; then
        log_event gateway WARNING "no gateway to test (no default route)"
        return
    fi

    if ping -c 2 -W "$NET_TIMEOUT" -q "$GATEWAY" >/dev/null 2>&1; then
        log_event gateway OK "gateway $GATEWAY answers ping"
        return
    fi

    # Some gateways (Azure, some firewalls) drop ICMP. If the neighbour
    # table has a MAC for it, layer 2 is fine and this is only a warning.
    if ip neigh show "$GATEWAY" | grep -q lladdr; then
        log_event gateway WARNING "gateway $GATEWAY has ARP entry but ignores ping"
    else
        log_event gateway CRITICAL "gateway $GATEWAY unreachable (no ping, no ARP entry)"
    fi
}

check_internet() {
    local ping_ok=0 http_ok=0
    ping -c 2 -W "$NET_TIMEOUT" -q "$PING_TARGET" >/dev/null 2>&1 && ping_ok=1
    curl -sS -o /dev/null --max-time "$NET_TIMEOUT" "$INTERNET_URL" 2>/dev/null && http_ok=1

    if (( ping_ok && http_ok )); then
        log_event internet OK "ping $PING_TARGET and $INTERNET_URL ok"
    elif (( http_ok )); then
        log_event internet OK "$INTERNET_URL ok (ICMP to $PING_TARGET blocked)"
    elif (( ping_ok )); then
        log_event internet WARNING "ping works but $INTERNET_URL failed (proxy/firewall/DNS?)"
    else
        log_event internet CRITICAL "no internet: ping $PING_TARGET and $INTERNET_URL both failed"
    fi
}

check_dns() {
    local answer resolver="${DNS_SERVER:-system resolver}"

    if ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
        log_event dns CRITICAL "no nameserver in /etc/resolv.conf"
        return
    fi

    if have dig; then
        local -a args=(+short +time="$NET_TIMEOUT" +tries=1 "$DNS_TEST_NAME" A)
        [[ -n "$DNS_SERVER" ]] && args=("@$DNS_SERVER" "${args[@]}")
        answer="$(dig "${args[@]}" 2>/dev/null | grep -E '^[0-9.]+$' | head -n1)"
    else
        # fallback when dnsutils isn't installed
        # shellcheck disable=SC2086  # empty DNS_SERVER must expand to nothing
        answer="$(nslookup -timeout="$NET_TIMEOUT" "$DNS_TEST_NAME" $DNS_SERVER 2>/dev/null \
                  | awk '/^Address: / {print $2}' | head -n1)"
    fi

    if [[ -n "$answer" ]]; then
        log_event dns OK "$DNS_TEST_NAME -> $answer via $resolver"
    else
        log_event dns CRITICAL "cannot resolve $DNS_TEST_NAME via $resolver"
    fi
}

check_ports() {
    local port
    for port in $TCP_PORTS; do
        if ss -H -ltn "sport = :$port" | grep -q .; then
            log_event "port:$port" OK "tcp/$port is listening"
        else
            log_event "port:$port" CRITICAL "nothing listening on tcp/$port"
        fi
    done
}

check_http() {
    [[ -z "$HTTP_URL" ]] && return
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$NET_TIMEOUT" "$HTTP_URL")"

    if [[ "$code" == "000" ]]; then
        log_event http CRITICAL "$HTTP_URL connection failed"
    elif (( code >= 400 )); then
        log_event http CRITICAL "$HTTP_URL returned HTTP $code"
    else
        log_event http OK "$HTTP_URL returned HTTP $code"
    fi
}
