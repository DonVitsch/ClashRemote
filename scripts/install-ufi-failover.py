#!/usr/bin/env python3
"""Push node-failover onto the currently selected 猫猫 device (UFI :2333)."""
import base64, hashlib, hmac, html, json, time, urllib.request
from pathlib import Path

HOST = "192.168.0.1"
PORT = 2333
PASSWORD = "admin"
UFI_SECRET = "minikano_kOyXz0Ciz4V7wR0IeKmJFYFQ20jd"
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "Sources/ClashRemote/Resources/node-failover.sh").read_text()
PAGE = (ROOT / "Sources/ClashRemote/Resources/cr-failover.html").read_text()
PLUGIN_JS = (ROOT / "Sources/ClashRemote/Resources/ufi-failover-plugin.js").read_text()

def sha256(d): return hashlib.sha256(d).digest()
def sha256_hex(d): return hashlib.sha256(d).hexdigest()
TOKEN = sha256_hex(PASSWORD.encode())

def ufi_sign(method, path, ts):
    raw = f"minikano{method}{path}{ts}".encode()
    digest = hmac.new(UFI_SECRET.encode(), raw, hashlib.md5).digest()
    mid = len(digest) // 2
    return sha256_hex(sha256(digest[:mid]) + sha256(digest[mid:]))

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def request(path, method="GET", body=None, timeout=40):
    ts = str(int(time.time() * 1000))
    sig = ufi_sign(method.upper(), path.split("?")[0], ts)
    headers = {
        "authorization": TOKEN,
        "kano-t": ts,
        "kano-sign": sig,
        "User-Agent": "ClashRemote/1.0",
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}{path}", data=data, headers=headers, method=method
    )
    with OPENER.open(req, timeout=timeout) as resp:
        return json.loads(resp.read())

def sh(cmd, t=25000):
    obj = request("/api/root_shell", "POST", {"command": cmd, "timeout": t}, timeout=t / 1000 + 20)
    if obj.get("error"):
        raise SystemExit("root_shell error: " + str(obj["error"]))
    return obj.get("result") or obj.get("content") or ""

def write_file(path, contents: str):
    b64 = base64.b64encode(contents.encode("utf-8")).decode("ascii")
    sh(f"rm -f {path}.b64 {path}")
    for i in range(0, len(b64), 4000):
        sh(f"printf '%s' '{b64[i:i+4000]}' >> {path}.b64")
    print(sh(f"(base64 -d {path}.b64 2>/dev/null || base64 -D {path}.b64) > {path} && rm -f {path}.b64 && wc -c {path}").strip())

WRAPPER = """#!/system/bin/sh
# --- clashremote-node-failover begin ---
REAL=/data/clash/Scripts/Clash.Service.clashremote.bak
"$REAL" "$@"
status=$?
case "$1" in
  start|restart)
    setsid /data/clash/Scripts/node-failover.sh loop >/dev/null 2>&1 </dev/null &
    ;;
  stop)
    /data/clash/Scripts/node-failover.sh stop >/dev/null 2>&1
    ;;
esac
exit $status
# --- clashremote-node-failover end ---
"""
CONF = """PORT=7788
SECRET=123456
INTERVAL=5
ENABLED=1
BATCH=4
DELAY_TIMEOUT=5000
CURL_MAX=7
"""

def main():
    print(sh("test -f /data/clash/Scripts/Clash.Service.clashremote.bak || cp /data/clash/Scripts/Clash.Service /data/clash/Scripts/Clash.Service.clashremote.bak; echo bak-ok"))
    write_file("/data/clash/Scripts/node-failover.sh", SCRIPT)
    write_file("/data/clash/Scripts/node-failover.conf", CONF)
    write_file("/data/clash/Scripts/Clash.Service", WRAPPER)
    print(sh("chmod 755 /data/clash/Scripts/node-failover.sh /data/clash/Scripts/Clash.Service /data/clash/Scripts/Clash.Service.clashremote.bak; ls -l /data/clash/Scripts/node-failover.sh /data/clash/Scripts/Clash.Service"))
    print(sh("/data/clash/Scripts/node-failover.sh stop >/dev/null 2>&1; setsid /data/clash/Scripts/node-failover.sh loop >/dev/null 2>&1 </dev/null & echo started; sleep 1; pid=$(cat /data/clash/Scripts/node-failover.pid 2>/dev/null); if [ -n \"$pid\" ] && [ -d /proc/$pid ]; then echo alive $pid; else echo dead; fi"))
    write_file("/data/clash/Proxy/WebUI/zashboard/cr-failover.html", PAGE)
    print(sh("chmod 644 /data/clash/Proxy/WebUI/zashboard/cr-failover.html; ls -l /data/clash/Proxy/WebUI/zashboard/cr-failover.html /data/clash/Proxy/WebUI/zashboard/cr-failover.json 2>/dev/null; echo JSON; cat /data/clash/Proxy/WebUI/zashboard/cr-failover.json 2>/dev/null"))

    plugin_block = (
        "<!-- [KANO_PLUGIN_START] 超时换节点.js -->\n"
        "//<script>\n"
        + PLUGIN_JS.strip()
        + "\n//</script>\n"
        "<!-- [KANO_PLUGIN_END] 超时换节点.js -->\n"
    )
    esc = html.escape(plugin_block, quote=False).replace("\n", "&#10;")
    write_file("/data/clash/Scripts/ufi-failover-plugin.esc", esc)
    print(sh(r"""
XML=/data/data/com.minikano.f50_sms/shared_prefs/kano_plugin_store.xml
FRAG=/data/clash/Scripts/ufi-failover-plugin.esc
if grep -q '超时换节点.js' "$XML"; then
  echo already-injected
else
  cp "$XML" "$XML.crbak"
  awk 'BEGIN{while((getline l < "'"$FRAG"'")>0) frag=frag l}
  { buf[NR]=$0 }
  END{
    for(i=1;i<=NR;i++){
      line=buf[i]
      if(i==NR-1 && line ~ /<\/string>/){
        sub(/<\/string>/, frag "</string>", line)
      }
      print line
    }
  }' "$XML" > "$XML.tmp" && mv "$XML.tmp" "$XML"
  echo injected
fi
grep -c '超时换节点.js' "$XML" || true
"""))

def push_page():
    write_file("/data/clash/Proxy/WebUI/zashboard/cr-failover.html", PAGE)
    print(sh("chmod 644 /data/clash/Proxy/WebUI/zashboard/cr-failover.html; wc -c /data/clash/Proxy/WebUI/zashboard/cr-failover.html"))


def strip_junk_nodes():
    """Drop airport placeholder proxies from provider YAML and reload locally."""
    awk_src = r"""
function junk_line(s) {
  return (s ~ /官网/ || s ~ /剩余流量/ || s ~ /套餐到期/ || s ~ /下次重置/ || s ~ /wulavpn/)
}
/type: select/ || /type: url-test/ || /type: fallback/ {
  gsub(/, '剩余流量：[^']*'/, "")
  gsub(/, '距离下次重置剩余：[^']*'/, "")
  gsub(/, '套餐到期：[^']*'/, "")
  gsub(/, 官网：wulavpn.com/, "")
  gsub(/官网：wulavpn.com, /, "")
  print
  next
}
junk_line($0) { print "DROP " substr($0,1,90) > "/dev/stderr"; next }
{ print }
"""
    write_file("/data/clash/Scripts/strip-junk.awk", awk_src)
    print(sh(r"""
for f in /data/clash/Proxy/proxies/*.yaml; do
  [ -f "$f" ] || continue
  awk -f /data/clash/Scripts/strip-junk.awk "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
echo STRIPPED
grep -n "官网" /data/clash/Proxy/proxies/*.yaml | head
curl -sS -m 20 -X PUT -H "Authorization: Bearer 123456" -H "Content-Type: application/json" \
  --data '{"path":"/data/clash/Proxy/config.yaml"}' \
  "http://127.0.0.1:7788/configs?force=true"
echo
echo RELOAD_DONE
"""))


if __name__ == "__main__":
    import sys
    if "--page" in sys.argv:
        push_page()
    elif "--strip-junk" in sys.argv:
        strip_junk_nodes()
    else:
        main()
        strip_junk_nodes()

