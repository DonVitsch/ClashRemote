import Foundation

enum NodeFailoverScript {
    static let path = "/data/clash/Scripts/node-failover.sh"
    static let confPath = "/data/clash/Scripts/node-failover.conf"
    static let pidPath = "/data/clash/Scripts/node-failover.pid"
    static let statusPath = "/data/clash/Scripts/node-failover.status"
    static let logPath = "/data/clash/Scripts/node-failover.log"
    static let historyPath = "/data/clash/Scripts/node-failover.history"
    /// 记住「脚本自己选定的节点」。当前节点跟它不一致 = 有人手动改过 → 固定住不动。
    static let pinPath = "/data/clash/Scripts/node-failover.pin"
    static let historyJSONPath = "/data/clash/Proxy/WebUI/zashboard/cr-failover-history.json"
    static let servicePath = "/data/clash/Scripts/Clash.Service"
    static let bakPath = "/data/clash/Scripts/Clash.Service.clashremote.bak"
    static let markerBegin = "# --- clashremote-node-failover begin ---"
    static let markerEnd = "# --- clashremote-node-failover end ---"

    static let source = #"""
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
PINFILE="/data/clash/Scripts/node-failover.pin"
HISTJSON="/data/clash/Proxy/WebUI/zashboard/cr-failover-history.json"
TMPDIR="/data/clash/Scripts/node-failover.tmp"

PORT=7788
SECRET=123456
INTERVAL=5
ENABLED=1
BATCH=12
DELAY_TIMEOUT=4000
CURL_MAX=7
FAILOVER_THRESHOLD=0
# 1 = 固定当前节点：只要还通就不换，只有超时才换（App 里的「固定当前节点」开关）。
PIN_MODE=0
EXCLUDE_KEYWORDS=''
EXCLUDE_REGIONS=''
PROVIDER_WHITELIST=''
WHITELIST_ENABLED=0
# 用户在 App 里拉黑的节点：精确名字 + 关键词（整个订阅/机场）。拉黑优先级最高。
BLOCKED_NODES=''
BLOCKED_KEYWORDS=''
ALWAYS_EXCLUDE_KEYWORDS='剩余
到期
流量
过期
官网
套餐
重置
距离下次
节点超时
请手动更新
请更新订阅'
PROBE_URL="http://www.gstatic.com/generate_204"

load_conf() {
    if [ -f "$CONF" ]; then
        # shellcheck disable=SC1090
        . "$CONF"
    fi
    if [ -n "${SECRET_B64:-}" ]; then
        SECRET=$(printf '%s' "$SECRET_B64" | base64 -d 2>/dev/null)
    fi
    [ -n "$PORT" ] || PORT=7788
    [ -n "$INTERVAL" ] || INTERVAL=5
    [ "$INTERVAL" -ge 5 ] 2>/dev/null || INTERVAL=5
    [ -n "$BATCH" ] || BATCH=12
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
    # 固定状态也写进 JSON：面板读它来显示「已固定 / 自动」，并用 auto 做「恢复自动」的目标。
    pin_node=$(json_escape "${PIN_NODE:-}")
    auto_node=$(json_escape "${AUTO_NODE:-}")
    printf '{"running":%s,"enabled":%s,"interval":%s,"detail":"%s","pid":"%s","log":"%s","pinMode":%s,"pin":"%s","auto":"%s"}\n' \
        "$running" "${ENABLED:-1}" "${INTERVAL:-5}" "$det" "$pid" "$log" \
        "${PIN_MODE:-0}" "$pin_node" "$auto_node" > "$JSONFILE" 2>/dev/null
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

# 把内核返回的 {"名字":延迟,...} 转成「延迟<TAB>名字」，只保留测通的。
# 内核不会返回没测通的节点，所以缺失即视为超时。没有 JSON 工具时返回 1。
json_map_pairs() {
    tool=$(json_tool)
    case "$tool" in
        jq)
            jq -r 'to_entries[] | select((.value|type)=="number") | select(.value > 0) | "\(.value)\t\(.key)"' 2>/dev/null
            ;;
        python3|python)
            "$tool" -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    raise SystemExit
if not isinstance(d,dict):
    raise SystemExit
for k,v in d.items():
    if isinstance(v,(int,float)) and v > 0:
        print("%d\t%s" % (int(v), k))
' 2>/dev/null
            ;;
        node)
            node -e '
let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{
  try{const d=JSON.parse(s); if(d&&typeof d==="object")
    for(const k of Object.keys(d)){const v=d[k]; if(typeof v==="number"&&v>0) console.log(v+"\t"+k);}
  }catch(e){}
});' 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# 让内核一次性把整组测完（内核内部并发），耗时就是一个 DELAY_TIMEOUT。
# 结果写进 $TMPDIR/gres；返回 0 表示"这次组测真的跑通了"。
probe_group_once() {
    group=$1
    [ -n "$group" ] || return 1
    case "$(json_tool)" in awk) return 1 ;; esac
    body=$(api_get "/group/$(urlenc "$group")/delay?timeout=${DELAY_TIMEOUT}&url=${PROBE_URL}" "$CURL_MAX")
    [ -n "$body" ] || return 1
    printf '%s\n' "$body" | json_map_pairs > "$TMPDIR/gres" || return 1
    [ -f "$TMPDIR/gres" ] || return 1
    return 0
}

pick_best_from_gres() {
    current=$1
    [ -f "$TMPDIR/gres" ] || return 0
    sort -n "$TMPDIR/gres" | while IFS="$(printf '\t')" read -r d n; do
        [ -n "$n" ] || continue
        [ "$n" = "$current" ] && continue
        is_excluded "$n" && continue
        if [ "$WHITELIST_ENABLED" = "1" ] && [ -n "$PROVIDER_WHITELIST" ]; then
            matches_any "$n" "$PROVIDER_WHITELIST" || continue
        fi
        printf '%s\t%s\n' "$n" "$d"
        break
    done
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
    echo "$n" | grep -F -qi "direct" && return 0
    echo "$n" | grep -F -qi "reject" && return 0
    return 1
}

matches_any() {
    name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    list=$2
    while IFS= read -r word; do
        [ -n "$word" ] || continue
        word=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')
        case "$name" in *"$word"*) return 0 ;; esac
    done <<EOF
$list
EOF
    return 1
}

# 精确匹配（区分大小写）：节点名是唯一的，不能被当子串用。
matches_line() {
    needle=$1
    while IFS= read -r word; do
        [ -n "$word" ] || continue
        [ "$word" = "$needle" ] && return 0
    done <<EOF
$2
EOF
    return 1
}

# 用户拉黑：精确节点名，或关键词命中。这两条优先于所有筛选规则。
is_blocked() {
    n=$1
    if [ -n "${BLOCKED_NODES:-}" ] && matches_line "$n" "$BLOCKED_NODES"; then
        return 0
    fi
    if [ -n "${BLOCKED_KEYWORDS:-}" ] && matches_any "$n" "$BLOCKED_KEYWORDS"; then
        return 0
    fi
    return 1
}

is_excluded() {
    n=$1
    is_blocked "$n" && return 0
    is_junk_name "$n" && return 0
    # 机场订阅里混进来的"信息节点"（剩余流量、套餐到期、官网…）名字像节点、测速也能通，
    # 但绝不该被选来跑流量。这里做一层不依赖配置的兜底 —— 旧版安装的 conf 没有关键词字段。
    matches_any "$n" "$ALWAYS_EXCLUDE_KEYWORDS" && return 0
    matches_any "$n" "$EXCLUDE_KEYWORDS" && return 0
    case ",$EXCLUDE_REGIONS," in
        *,hongkong,*) matches_any "$n" "香港
🇭🇰
hong kong
hongkong
hong-kong" && return 0 ;;
    esac
    case ",$EXCLUDE_REGIONS," in
        *,china,*)
            if matches_any "$n" "中国
大陆
🇨🇳
china
shanghai
beijing
shenzhen
guangzhou
chengdu" && ! matches_any "$n" "台湾
🇹🇼
taiwan
taipei"; then return 0; fi ;;
    esac
    case ",$EXCLUDE_REGIONS," in
        *,japan,*) matches_any "$n" "日本
🇯🇵
japan
tokyo
osaka" && return 0 ;;
    esac
    case ",$EXCLUDE_REGIONS," in
        *,usa,*) matches_any "$n" "美国
🇺🇸
united states
los angeles
 usa
usa
seattle
san jose
new york" && return 0 ;;
    esac
    case ",$EXCLUDE_REGIONS," in
        *,singapore,*) matches_any "$n" "新加坡
🇸🇬
singapore" && return 0 ;;
    esac
    if [ "$WHITELIST_ENABLED" = "1" ] && [ -n "$PROVIDER_WHITELIST" ]; then
        matches_any "$n" "$PROVIDER_WHITELIST" || return 0
    fi
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
        child=$(proxy_body "$n")
        if is_group "$child"; then
            continue
        fi
        is_excluded "$n" && continue
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
    owner=$(cat "$TMPDIR/owner" 2>/dev/null)
    root=$(cat "$TMPDIR/root" 2>/dev/null)

    # 快路径：一个请求让内核把整组并发测完，几秒出结果。
    # 以前是逐个节点发 /proxies/{name}/delay，每批都要等到最慢的那个，
    # 一批里撞上一个超时节点就白等一个超时 —— 几十个节点要等一两分钟。
    rm -f "$TMPDIR/gres"
    for g in "$owner" "$root"; do
        [ -n "$g" ] || continue
        probe_group_once "$g" || continue
        r=$(pick_best_from_gres "$current")
        if [ -n "$r" ]; then printf '%s\n' "$r"; return; fi
    done
    # 组测跑通了（只是没有能用的节点）就别再逐个耗时间了
    if [ -f "$TMPDIR/gres" ]; then return; fi

    : > "$TMPDIR/cands"
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

    group_has() {
        group_body=$(proxy_body "$1")
        printf '%s' "$group_body" | json_all | grep -F -x "$2" >/dev/null 2>&1
    }

    if group_has "$owner" "$node"; then
        put_select "$owner" "$node"
        target=$owner
    elif group_has "$root" "$node"; then
        target=$root
    else
        target=""
        body=$(proxy_body "$root")
        printf '%s' "$body" | json_all > "$TMPDIR/root-groups"
        while IFS= read -r child; do
            if group_has "$child" "$node"; then
                put_select "$child" "$node"
                target=$child
                break
            fi
        done < "$TMPDIR/root-groups"
    fi
    [ -n "$target" ] || return 1

    if [ "$mode" != "global" ] && [ "$root" != "$target" ]; then
        if group_has "$root" "$node"; then
            put_select "$root" "$node"
        elif group_has "$root" "$target"; then
            put_select "$root" "$target"
        fi
    fi

    if [ "$mode" = "global" ] && [ "$target" != "GLOBAL" ]; then
        if group_has "GLOBAL" "$node"; then
            put_select "GLOBAL" "$node"
        elif group_has "GLOBAL" "$target"; then
            put_select "GLOBAL" "$target"
        fi
    elif [ "$target" = "$root" ] && [ "$target" != "$owner" ]; then
        put_select "$root" "$node"
    fi
}

once() {
    load_conf
    mkdir -p "$TMPDIR"
    # 每轮从零开始算固定状态，别让上一轮的残留值混进 JSON
    PIN_NODE=""
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

    # --- 固定：谁手动改了节点就尊重谁 ---
    # PINFILE 存的是「脚本自己选定的节点」。当前节点跟它不一致，说明是别处改的
    # （面板上点了节点、App 里手动选、其它客户端）—— 那是用户的明确意愿，固定住不动，
    # 直到这个节点真的超时为止。脚本自己换完节点会更新 PINFILE，所以不会被误判成手动。
    AUTO_NODE=$(cat "$PINFILE" 2>/dev/null)
    if [ -z "$AUTO_NODE" ]; then
        printf '%s' "$leaf" > "$PINFILE" 2>/dev/null
        AUTO_NODE="$leaf"
    fi
    PIN_NODE=""
    if [ "$PIN_MODE" = "1" ] || [ "$AUTO_NODE" != "$leaf" ]; then
        PIN_NODE="$leaf"
    fi

    if is_excluded "$leaf"; then
        # 被筛选/拉黑的节点不享受固定，直接换走
        PIN_NODE=""
        log "excluded leaf $leaf, probing away"
        set_status "excluded $leaf, probing"
        delay=0
    else
        delay=$(test_delay "$leaf")
        keep=0
        if [ "$delay" -gt 0 ] 2>/dev/null; then
            if [ -n "$PIN_NODE" ]; then
                # 固定：只要还通就留着，再慢也不换
                keep=1
            elif [ "$FAILOVER_THRESHOLD" -le 0 ] || [ "$delay" -lt "$FAILOVER_THRESHOLD" ]; then
                keep=1
            fi
        fi
        if [ "$keep" = "1" ]; then
            if [ -n "$PIN_NODE" ]; then
                set_status "pinned ${leaf} ${delay}ms"
            else
                set_status "ok ${leaf} ${delay}ms"
            fi
            return 0
        fi
        log "slow or timeout $leaf, probing all"
        set_status "slow or timeout $leaf, probing all"
    fi
    result=$(probe_best "$leaf")
    best_n=$(printf '%s' "$result" | awk -F '\t' '{print $1}')
    best_d=$(printf '%s' "$result" | awk -F '\t' '{print $2}')
    if [ -z "$best_n" ] || { [ "$delay" -gt 0 ] 2>/dev/null && [ "$best_d" -ge "$delay" ] 2>/dev/null; }; then
        log "no faster candidate after $leaf"
        set_status "no faster candidate $leaf"
        return 0
    fi
    if ! select_like_mac "$best_n"; then
        log "candidate $best_n has no selectable group"
        set_status "candidate unavailable $best_n"
        return 0
    fi
    close_conns
    # 这一轮是脚本自己换的：记下来，下一轮才不会把这个新节点当成"手动固定"。
    printf '%s' "$best_n" > "$PINFILE" 2>/dev/null
    PIN_NODE=""
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
    # 守护（重新）启动时把「基线节点」丢掉：重启后内核选中的节点可能跟上次不一样，
    # 留着旧基线会被误判成"有人手动固定了"。固定开关仍然看 conf 里的 PIN_MODE。
    rm -f "$PINFILE" 2>/dev/null
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

"""#

    static func profileConf(_ profile: LocalProfile) -> String {
        func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        func lines(_ values: [String]) -> String {
            quoted(values.map {
                $0.replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "CR_FAILOVER_PROFILE_EOF", with: " ")
            }
                .filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let regions = RegionExclusion.allCases.filter { profile.regionExclusions.contains($0) }
            .map { String(describing: $0) }.joined(separator: ",")
        return """
        FAILOVER_THRESHOLD=\(max(0, profile.failoverThreshold))
        PIN_MODE=\(profile.pinnedNode ? 1 : 0)
        EXCLUDE_KEYWORDS=\(lines(profile.filterKeywords))
        EXCLUDE_REGIONS=\(quoted(regions))
        PROVIDER_WHITELIST=\(lines(profile.providerWhitelist))
        WHITELIST_ENABLED=\(profile.providerWhitelistEnabled ? 1 : 0)
        BLOCKED_NODES=\(lines(profile.blockedNodes))
        BLOCKED_KEYWORDS=\(lines(profile.blockedKeywords))
        """
    }

    static func conf(secret: String, interval: Int, enabled: Bool, profile: LocalProfile) -> String {
        let seconds = max(interval, 5)
        let on = enabled ? 1 : 0
        return """
        PORT=7788
        SECRET=\(shellQuoted(secret))
        INTERVAL=\(seconds)
        ENABLED=\(on)
        BATCH=12
        DELAY_TIMEOUT=4000
        CURL_MAX=7
        \(profileConf(profile))
        """
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Clash.Service does `exec clashctl`, so anything after that never runs.
    /// Keep the original as `.bak` and replace Service with this wrapper.
    static func wrapperService() -> String {
        """
        #!/system/bin/sh
        \(markerBegin)
        REAL=\(bakPath)
        "$REAL" "$@"
        status=$?
        case "$1" in
          start|restart)
            setsid \(path) loop >/dev/null 2>&1 </dev/null &
            ;;
          stop)
            \(path) stop >/dev/null 2>&1
            ;;
        esac
        exit $status
        \(markerEnd)
        """
    }

    static func parseConf(_ raw: String) -> (interval: Int, enabled: Bool) {
        var interval = 5
        var enabled = true
        for line in raw.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("INTERVAL="), let value = Int(s.dropFirst("INTERVAL=".count)) {
                interval = max(value, 5)
            } else if s.hasPrefix("ENABLED=") {
                enabled = s.hasSuffix("1")
            }
        }
        return (interval, enabled)
    }

    static func parseStatusDump(_ dump: String) -> DeviceFailoverStatus {
        var status = DeviceFailoverStatus()
        let parts = dump.components(separatedBy: "---CONF---")
        let head = parts.first ?? ""
        status.installed = head.contains("INSTALLED=yes")
        status.hooked = head.contains("HOOKED=yes")
        status.running = head.contains("RUNNING=yes")

        let afterConf = parts.dropFirst().joined(separator: "---CONF---")
        let statusParts = afterConf.components(separatedBy: "---STATUS---")
        let conf = statusParts.first ?? ""
        let parsed = parseConf(conf)
        status.interval = parsed.interval
        status.enabled = parsed.enabled

        let afterStatus = statusParts.dropFirst().joined(separator: "---STATUS---")
        let logParts = afterStatus.components(separatedBy: "---LOG---")
        status.detail = (logParts.first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        status.log = logParts.dropFirst().joined(separator: "---LOG---")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        status.updatedAt = Date()
        return status
    }

    private static let historyStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    static func parseHistory(_ raw: String, source: String = "设备") -> [FailoverEvent] {
        raw.split(whereSeparator: \.isNewline).reversed().compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("{"),
                  let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let from = JSONValue.string(obj["from"])
            let to = JSONValue.string(obj["to"])
            guard !from.isEmpty, !to.isEmpty else { return nil }
            let at = historyStamp.date(from: JSONValue.string(obj["at"])) ?? Date()
            return FailoverEvent(
                at: at,
                from: from,
                to: to,
                delay: JSONValue.int(obj["ms"]),
                source: source
            )
        }
    }

    static let startCommand = """
    /data/clash/Scripts/node-failover.sh stop >/dev/null 2>&1
    setsid /data/clash/Scripts/node-failover.sh loop >/dev/null 2>&1 </dev/null &
    echo started
    """
}
