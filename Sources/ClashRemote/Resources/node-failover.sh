#!/system/bin/sh
# Clash Remote: sticky failover on 猫猫 / Mihomo.
# Only switch when the current leaf times out. Idle loop is sleep.

export PATH="/data/data/com.minikano.f50_sms/files:/system/bin:/system/xbin:${PATH:-}"

CONF="/data/clash/Scripts/node-failover.conf"
PIDFILE="/data/clash/Scripts/node-failover.pid"
LOGFILE="/data/clash/Scripts/node-failover.log"
STATUSFILE="/data/clash/Scripts/node-failover.status"
JSONFILE="/data/clash/Proxy/WebUI/zashboard/cr-failover.json"
HISTFILE="/data/clash/Scripts/node-failover.history"
HISTJSON="/data/clash/Proxy/WebUI/zashboard/cr-failover-history.json"
TMPDIR="/data/clash/Scripts/node-failover.tmp"

PORT=7788
SECRET=123456
INTERVAL=5
ENABLED=1
BATCH=4
DELAY_TIMEOUT=5000
CURL_MAX=7
PROBE_URL="http://www.gstatic.com/generate_204"

load_conf() {
    if [ -f "$CONF" ]; then
        # shellcheck disable=SC1090
        . "$CONF"
    fi
    [ -n "$PORT" ] || PORT=7788
    [ -n "$INTERVAL" ] || INTERVAL=5
    [ "$INTERVAL" -ge 5 ] 2>/dev/null || INTERVAL=5
    [ -n "$BATCH" ] || BATCH=4
    [ -n "$ENABLED" ] || ENABLED=1
    [ -n "$SECRET" ] || SECRET=123456
}

have() {
    command -v "$1" >/dev/null 2>&1
}

log() {
    line="$(date '+%m-%d %H:%M:%S' 2>/dev/null) $*"
    echo "$line" >> "$LOGFILE" 2>/dev/null
    if have tail; then
        tail -n 40 "$LOGFILE" > "$LOGFILE.rot" 2>/dev/null && mv "$LOGFILE.rot" "$LOGFILE" 2>/dev/null
    fi
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

append_history() {
    from=$(json_escape "$1")
    to=$(json_escape "$2")
    ms=${3:-0}
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    printf '{"at":"%s","from":"%s","to":"%s","ms":%s}\n' "$ts" "$from" "$to" "$ms" >> "$HISTFILE"
    if have tail; then
        tail -n 80 "$HISTFILE" > "$HISTFILE.rot" 2>/dev/null && mv "$HISTFILE.rot" "$HISTFILE" 2>/dev/null
    fi
    if have jq; then
        tail -n 80 "$HISTFILE" 2>/dev/null | jq -s '.' > "$HISTJSON" 2>/dev/null
    else
        printf '[' > "$HISTJSON"
        awk 'NR>1{printf ","} {printf "%s", $0}' "$HISTFILE" >> "$HISTJSON" 2>/dev/null
        printf ']\n' >> "$HISTJSON"
    fi
}

set_status() {
    printf '%s\n' "$*" > "$STATUSFILE" 2>/dev/null
    pid=""
    running=0
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            running=1
        fi
    fi
    det=$(printf '%s' "$*" | sed 's/\\/\\\\/g; s/"/\\"/g')
    log=$(tail -n 6 "$LOGFILE" 2>/dev/null | tr '\n' '|' | sed 's/"/\\"/g')
    printf '{"running":%s,"enabled":%s,"interval":%s,"detail":"%s","pid":"%s","log":"%s"}\n' \
        "$running" "${ENABLED:-1}" "${INTERVAL:-5}" "$det" "$pid" "$log" > "$JSONFILE" 2>/dev/null
}

find_curl() {
    for c in /data/data/com.minikano.f50_sms/files/curl /system/bin/curl curl; do
        if [ -x "$c" ]; then echo "$c"; return; fi
        w=$(command -v "$c" 2>/dev/null) || true
        if [ -n "$w" ] && [ -x "$w" ]; then echo "$w"; return; fi
    done
}

CURL=$(find_curl)

http() {
    method=$1
    path=$2
    body=${3:-}
    max=${4:-$CURL_MAX}
    url="http://127.0.0.1:${PORT}${path}"
    [ -n "$CURL" ] || return 1
    if [ -n "$body" ]; then
        "$CURL" -sS --max-time "$max" \
            -H "Authorization: Bearer ${SECRET}" \
            -H "Content-Type: application/json" \
            -X "$method" \
            --data "$body" \
            "$url" 2>/dev/null
    else
        "$CURL" -sS --max-time "$max" \
            -H "Authorization: Bearer ${SECRET}" \
            -X "$method" \
            "$url" 2>/dev/null
    fi
}

json_tool() {
    if have jq; then echo jq; return; fi
    if have python3; then echo python3; return; fi
    if have python; then echo python; return; fi
    if have node; then echo node; return; fi
    echo awk
}

json_get() {
    field=$1
    tool=$(json_tool)
    case "$tool" in
        jq)
            jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null
            ;;
        python3|python)
            "$tool" -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit
v=d.get(sys.argv[1],"")
if v is None: v=""
print(v)
' "$field" 2>/dev/null
            ;;
        node)
            node -e '
let s=""; process.stdin.on("data",c=>s+=c); process.stdin.on("end",()=>{
  try { const d=JSON.parse(s); const v=d[process.argv[1]]; console.log(v==null?"":v); }
  catch(e){ console.log(""); }
});
' "$field" 2>/dev/null
            ;;
        *)
            tr ',' '\n' | grep -m1 -F "\"$field\"" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p; s/.*\"$field\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" | head -n 1
            ;;
    esac
}

json_all() {
    tool=$(json_tool)
    case "$tool" in
        jq)
            jq -r '.all[]? // empty' 2>/dev/null
            ;;
        python3|python)
            "$tool" -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    raise SystemExit
for x in (d.get("all") or []):
    print(x)
' 2>/dev/null
            ;;
        node)
            node -e '
let s=""; process.stdin.on("data",c=>s+=c); process.stdin.on("end",()=>{
  try { const d=JSON.parse(s); (d.all||[]).forEach(x=>console.log(x)); }
  catch(e){}
});
' 2>/dev/null
            ;;
        *)
            tr ',' '\n' | sed -n 's/.*"all"[[:space:]]*:[[:space:]]*\[\(.*\)\].*/\1/p' | tr '"' '\n' | grep -v '^[[:space:]]*$' | grep -v '^\[$'
            ;;
    esac
}

urlenc() {
    raw=$1
    tool=$(json_tool)
    case "$tool" in
        jq)
            jq -nr --arg s "$raw" '$s|@uri' 2>/dev/null
            ;;
        python3|python)
            "$tool" -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$raw" 2>/dev/null
            ;;
        node)
            node -e 'console.log(encodeURIComponent(process.argv[1]))' "$raw" 2>/dev/null
            ;;
        *)
            printf '%s' "$raw" | od -An -t x1 | awk '{
                for (i = 1; i <= NF; i++) printf "%%%s", toupper($i)
            } END { print "" }'
            ;;
    esac
}

api_get() {
    http GET "$1" "" "${2:-$CURL_MAX}"
}

is_hidden() {
    n=$1
    case "$n" in
        ""|"—"|DIRECT|REJECT|PASS|COMPATIBLE|Reject|Direct|MATCH) return 0 ;;
    esac
    return 1
}

is_junk_name() {
    n=$1
    is_hidden "$n" && return 0
    echo "$n" | grep -F -q "直连" && return 0
    echo "$n" | grep -F -q "大陆" && return 0
    echo "$n" | grep -F -q "国内" && return 0
    echo "$n" | grep -F -q "境内" && return 0
    echo "$n" | grep -F -q "🇨🇳" && return 0
    echo "$n" | grep -F -qi "direct" && return 0
    echo "$n" | grep -F -qi "reject" && return 0
    echo "$n" | grep -F -qi "mainland" && return 0
    echo "$n" | grep -F -q "剩余" && return 0
    echo "$n" | grep -F -q "到期" && return 0
    echo "$n" | grep -F -q "重置" && return 0
    echo "$n" | grep -F -q "过期" && return 0
    echo "$n" | grep -F -q "套餐" && return 0
    echo "$n" | grep -F -q "流量" && return 0
    echo "$n" | grep -F -q "官网" && return 0
    echo "$n" | grep -F -qi "wulavpn" && return 0
    return 1
}

is_hongkong() {
    n=$1
    echo "$n" | grep -F -q "香港" && return 0
    echo "$n" | grep -F -q "🇭🇰" && return 0
    folded=$(echo "$n" | tr 'A-Z' 'a-z')
    echo "$folded" | grep -F -q "hong kong" && return 0
    echo "$folded" | grep -F -q "hongkong" && return 0
    echo "$folded" | grep -F -q "hong-kong" && return 0
    return 1
}

is_group() {
    body=$1
    all=$(printf '%s' "$body" | json_all)
    [ -n "$all" ]
}

proxy_body() {
    enc=$(urlenc "$1")
    api_get "/proxies/${enc}"
}

test_delay() {
    enc=$(urlenc "$1")
    path="/proxies/${enc}/delay?timeout=${DELAY_TIMEOUT}&url=${PROBE_URL}"
    body=$(api_get "$path" "$CURL_MAX")
    d=$(printf '%s' "$body" | json_get delay)
    case "$d" in
        ""|0|-1) echo 0 ;;
        *) echo "$d" ;;
    esac
}

pick_root() {
    mode=$(api_get "/configs" | json_get mode)
    mode=$(echo "$mode" | tr 'A-Z' 'a-z')
    echo "$mode" > "$TMPDIR/mode"
    if [ "$mode" = "direct" ]; then
        echo ""
        return
    fi
    if [ "$mode" = "global" ]; then
        echo "GLOBAL"
        return
    fi
    for g in "选择节点" "节点选择" "漏网之鱼" "手动选择" "PROXY" "Proxy" "proxy" "代理" "🚀" "Select"; do
        is_junk_name "$g" && continue
        [ "$g" = "GLOBAL" ] && continue
        body=$(proxy_body "$g")
        if is_group "$body"; then
            echo "$g"
            return
        fi
    done
    echo "GLOBAL"
}

resolve_leaf() {
    name=$1
    depth=0
    chain=$name
    owner=$name
    leaf=$name
    while [ "$depth" -lt 8 ]; do
        body=$(proxy_body "$name")
        now=$(printf '%s' "$body" | json_get now)
        if [ -z "$now" ]; then
            leaf=$name
            break
        fi
        child=$(proxy_body "$now")
        if is_group "$child"; then
            owner=$name
            chain="${chain} / ${now}"
            name=$now
            depth=$((depth + 1))
            continue
        fi
        owner=$name
        leaf=$now
        chain="${chain} / ${now}"
        break
    done
    printf '%s\n' "$leaf" > "$TMPDIR/leaf"
    printf '%s\n' "$owner" > "$TMPDIR/owner"
    printf '%s\n' "$chain" > "$TMPDIR/chain"
    printf '%s\n' "$name" > "$TMPDIR/rootish"
}

collect_leaves() {
    group=$1
    body=$(proxy_body "$group")
    printf '%s' "$body" | json_all | while IFS= read -r n; do
        [ -n "$n" ] || continue
        is_junk_name "$n" && continue
        is_hongkong "$n" && continue
        child=$(proxy_body "$n")
        if is_group "$child"; then
            continue
        fi
        echo "$n"
    done
}

collect_nested() {
    group=$1
    body=$(proxy_body "$group")
    printf '%s' "$body" | json_all | while IFS= read -r n; do
        [ -n "$n" ] || continue
        child=$(proxy_body "$n")
        if is_group "$child"; then
            collect_leaves "$n"
        fi
    done
}

uniq_lines() {
    tool=$(json_tool)
    case "$tool" in
        python3|python)
            "$tool" -c '
import sys
seen=set()
for line in sys.stdin:
    s=line.rstrip("\n")
    if s and s not in seen:
        seen.add(s)
        print(s)
'
            ;;
        *)
            awk 'NF && !a[$0]++'
            ;;
    esac
}

put_select() {
    group=$1
    name=$2
    enc=$(urlenc "$group")
    # JSON string escape
    escaped=$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
    http PUT "/proxies/${enc}" "{\"name\":\"${escaped}\"}" 8 >/dev/null
}

close_conns() {
    http DELETE "/connections" "" 8 >/dev/null
}

probe_best() {
    current=$1
    : > "$TMPDIR/cands"
    owner=$(cat "$TMPDIR/owner" 2>/dev/null)
    root=$(cat "$TMPDIR/root" 2>/dev/null)
    mode=$(cat "$TMPDIR/mode" 2>/dev/null)

    {
        [ -n "$owner" ] && collect_leaves "$owner"
        if [ -n "$root" ] && [ "$root" != "$owner" ]; then
            collect_leaves "$root"
            collect_nested "$root"
        fi
        if [ "$mode" = "global" ]; then
            collect_leaves "GLOBAL"
            collect_nested "GLOBAL"
        fi
    } | uniq_lines | while IFS= read -r n; do
        [ "$n" = "$current" ] && continue
        echo "$n"
    done > "$TMPDIR/cands"

    if [ ! -s "$TMPDIR/cands" ]; then
        echo ""
        return
    fi

    rm -rf "$TMPDIR/res"
    mkdir -p "$TMPDIR/res"
    idx=0
    batch_n=0
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        (
            d=$(test_delay "$n")
            printf '%s %s\n' "$d" "$n" > "$TMPDIR/res/$idx"
        ) &
        idx=$((idx + 1))
        batch_n=$((batch_n + 1))
        if [ "$batch_n" -ge "$BATCH" ]; then
            wait
            batch_n=0
        fi
    done < "$TMPDIR/cands"
    wait

    best_d=999999
    best_n=""
    for f in "$TMPDIR/res"/*; do
        [ -f "$f" ] || continue
        d=$(awk '{print $1}' "$f")
        n=$(awk '{print substr($0, index($0,$2))}' "$f")
        case "$d" in
            ""|0|-1) continue ;;
        esac
        if [ "$d" -lt "$best_d" ] 2>/dev/null; then
            best_d=$d
            best_n=$n
        fi
    done
    if [ -n "$best_n" ]; then
        printf '%s\t%s\n' "$best_n" "$best_d"
    fi
}

select_like_mac() {
    node=$1
    owner=$(cat "$TMPDIR/owner")
    root=$(cat "$TMPDIR/root")
    mode=$(cat "$TMPDIR/mode")

    put_select "$owner" "$node"

    if [ "$mode" != "global" ] && [ -n "$root" ] && [ "$root" != "$owner" ]; then
        body=$(proxy_body "$root")
        all=$(printf '%s' "$body" | json_all)
        if echo "$all" | grep -F -x "$node" >/dev/null 2>&1; then
            put_select "$root" "$node"
        elif echo "$all" | grep -F -x "$owner" >/dev/null 2>&1; then
            put_select "$root" "$owner"
        fi
    fi

    if [ "$mode" = "global" ] && [ "$owner" != "GLOBAL" ]; then
        body=$(proxy_body "GLOBAL")
        all=$(printf '%s' "$body" | json_all)
        if echo "$all" | grep -F -x "$node" >/dev/null 2>&1; then
            put_select "GLOBAL" "$node"
        elif echo "$all" | grep -F -x "$owner" >/dev/null 2>&1; then
            put_select "GLOBAL" "$owner"
        fi
    fi
}

once() {
    load_conf
    mkdir -p "$TMPDIR"
    ver=$(api_get "/version")
    if [ -z "$ver" ]; then
        set_status "clash not ready"
        return 0
    fi
    root=$(pick_root)
    if [ -z "$root" ]; then
        set_status "idle direct"
        return 0
    fi
    printf '%s\n' "$root" > "$TMPDIR/root"
    resolve_leaf "$root"
    leaf=$(cat "$TMPDIR/leaf")
    # leaf that is still a group name should not be switched
    if is_group "$(proxy_body "$leaf")"; then
        set_status "skip group $leaf"
        return 0
    fi

    if is_junk_name "$leaf"; then
        log "junk leaf $leaf, probing away"
        set_status "junk $leaf, probing"
        delay=0
    else
        delay=$(test_delay "$leaf")
        if [ "$delay" -gt 0 ] 2>/dev/null; then
            set_status "ok ${leaf} ${delay}ms"
            return 0
        fi
        log "timeout $leaf, probing all"
        set_status "timeout $leaf, probing all"
    fi
    result=$(probe_best "$leaf")
    best_n=$(printf '%s' "$result" | awk -F '\t' '{print $1}')
    best_d=$(printf '%s' "$result" | awk -F '\t' '{print $2}')
    if [ -z "$best_n" ]; then
        log "no candidate after $leaf timeout"
        set_status "timeout $leaf, no candidate"
        return 0
    fi
    select_like_mac "$best_n"
    close_conns
    append_history "$leaf" "$best_n" "$best_d"
    log "switched $leaf -> $best_n (${best_d}ms)"
    set_status "switched $leaf -> $best_n (${best_d}ms)"
}

is_running() {
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            return 0
        fi
    fi
    return 1
}

stop_loop() {
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null
            sleep 0.2 2>/dev/null
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$PIDFILE"
    fi
}

loop() {
    load_conf
    stop_loop
    echo $$ > "$PIDFILE"
    set_status "loop start interval=${INTERVAL}s"
    log "loop start interval=${INTERVAL}s"
    trap '' HUP
    trap 'rm -f "$PIDFILE"; set_status "stopped"; exit 0' INT TERM
    while true; do
        load_conf
        if [ "$ENABLED" = "1" ]; then
            once
        else
            set_status "disabled"
        fi
        sleep "$INTERVAL"
    done
}

cmd=${1:-once}
case "$cmd" in
    loop) loop ;;
    stop) stop_loop ;;
    status)
        load_conf
        if is_running; then echo running; else echo stopped; fi
        cat "$STATUSFILE" 2>/dev/null
        ;;
    once) once ;;
    *) once ;;
esac
