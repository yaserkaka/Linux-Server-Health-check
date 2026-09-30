#!/usr/bin/env bash
# Quick network overview for when something is wrong and you just SSH'd in.
# Read-only, changes nothing.
#
#   sudo ./net-troubleshoot.sh [name-to-resolve]
#
# sudo is only needed so ss can show process names.

set -uo pipefail
export LC_ALL=C

NAME="${1:-ubuntu.com}"
TIMEOUT=3

if [[ -t 1 ]]; then
    B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; N=$'\e[0m'
else
    B=""; G=""; R=""; N=""
fi

section() { printf '\n%s== %s ==%s\n' "$B" "$1" "$N"; }
pass()    { printf '%s[ OK ]%s %s\n' "$G" "$N" "$1"; }
fail()    { printf '%s[FAIL]%s %s\n' "$R" "$N" "$1"; }

section "ip addr"
ip -br addr
echo
ip addr show scope global

section "ip route"
ip route
gw="$(ip route show default | awk '/default/ {for (i=1; i<NF; i++) if ($i=="via") print $(i+1); exit}')"
if [[ -n "$gw" ]]; then
    pass "default gateway: $gw"
else
    fail "no default route"
fi

section "/etc/resolv.conf"
ls -l /etc/resolv.conf
grep -v '^#' /etc/resolv.conf | sed '/^$/d'
if command -v resolvectl >/dev/null 2>&1; then
    echo
    echo "upstream DNS (resolvectl):"
    resolvectl dns 2>/dev/null | sed 's/^/  /'
fi

section "DNS test: $NAME"
if command -v dig >/dev/null 2>&1; then
    out="$(dig +time=$TIMEOUT +tries=1 "$NAME" A)"
    answers="$(awk '/^;; ANSWER SECTION/ {f=1; next} f && NF==0 {f=0} f {print $NF}' <<< "$out")"
    qtime="$(awk '/Query time/ {print $4, $5}' <<< "$out")"
    server="$(awk '/SERVER:/ {print $3}' <<< "$out")"
    if [[ -n "$answers" ]]; then
        pass "$NAME -> $(echo "$answers" | tr '\n' ' ')(${qtime:-?}, server $server)"
    else
        fail "$NAME did not resolve (status: $(awk -F'status: ' '/status:/ {split($2,a,","); print a[1]}' <<< "$out"))"
    fi
else
    nslookup "$NAME" || fail "nslookup $NAME failed"
fi

section "gateway test"
if [[ -n "$gw" ]]; then
    if ping -c 3 -W $TIMEOUT "$gw" | tail -n2; then
        pass "gateway $gw answers ping"
    else
        fail "gateway $gw does not answer ping"
        echo "neighbour entry: $(ip neigh show "$gw")"
    fi
else
    fail "skipped, no gateway"
fi

section "internet test"
if ping -c 2 -W $TIMEOUT -q 1.1.1.1 >/dev/null 2>&1; then
    pass "ping 1.1.1.1"
else
    fail "ping 1.1.1.1"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time $TIMEOUT https://www.google.com)"
if [[ "$code" != "000" ]]; then
    pass "https://www.google.com -> HTTP $code"
else
    fail "https://www.google.com unreachable"
fi

section "listening ports (tcp/udp)"
ss -tulpn

section "local http"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time $TIMEOUT http://localhost/)"
if [[ "$code" != "000" ]]; then
    pass "http://localhost/ -> HTTP $code"
else
    fail "nothing answering on http://localhost/"
fi
