#!/usr/bin/env python3
"""Install Clash Remote node-failover + web panel onto RAX3000M over SSH.

LuCI ubus file.exec is denied, and OpenClash custom overwrite.sh on this
router hits `exit 0` before any appended hook. SSH writes files for real.
"""
import os
import subprocess
import tempfile
from pathlib import Path

HOST = "192.168.10.1"
USERNAME = "root"
PASSWORD = "password"
INTERVAL = 5
ENABLED = 1

ROOT = Path(__file__).resolve().parents[1]
RAW = (ROOT / "Sources/ClashRemote/Resources/node-failover.sh").read_text()
PAGE_SRC = (ROOT / "Sources/ClashRemote/Resources/cr-failover.html").read_text()

PATH = "/etc/openclash/clashremote-failover.sh"
CONF = "/etc/openclash/clashremote-failover.conf"
PID = "/var/run/clashremote-failover.pid"
INIT = "/etc/init.d/clashremote-failover"
OVERWRITE = "/etc/openclash/custom/openclash_custom_overwrite.sh"
UI = "/usr/share/openclash/ui"
BEGIN = "# --- clashremote-node-failover begin ---"
END = "# --- clashremote-node-failover end ---"

SCRIPT = (
    RAW.replace("#!/system/bin/sh", "#!/bin/sh")
    .replace(
        'export PATH="/data/data/com.minikano.f50_sms/files:/system/bin:/system/xbin:${PATH:-}"',
        'export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"',
    )
    .replace("/data/clash/Scripts/node-failover.conf", CONF)
    .replace("/data/clash/Scripts/node-failover.pid", PID)
    .replace("/data/clash/Scripts/node-failover.log", "/tmp/clashremote-failover.log")
    .replace("/data/clash/Scripts/node-failover.status", "/tmp/clashremote-failover.status")
    .replace("/data/clash/Proxy/WebUI/zashboard/cr-failover.json", f"{UI}/cr-failover.json")
    .replace("/data/clash/Scripts/node-failover.history", "/etc/openclash/clashremote-failover.history")
    .replace(
        "/data/clash/Proxy/WebUI/zashboard/cr-failover-history.json",
        f"{UI}/cr-failover-history.json",
    )
    .replace("/data/clash/Scripts/node-failover.tmp", "/tmp/clashremote-failover.tmp")
    .replace("PORT=7788", "PORT=9090")
    .replace(
        "for c in /data/data/com.minikano.f50_sms/files/curl /system/bin/curl curl; do",
        "for c in /usr/bin/curl /bin/curl curl; do",
    )
    .replace(
        "have() {",
        """resolve_ui() {
    if [ -d /usr/share/openclash/ui ]; then
        echo /usr/share/openclash/ui
        return
    fi
    echo /tmp
}
have() {""",
    )
    .replace(
        """    [ -n "$SECRET" ] || SECRET=123456
}
""",
        """    [ -n "$SECRET" ] || SECRET=123456
    uid=$(resolve_ui)
    JSONFILE="$uid/cr-failover.json"
    HISTJSON="$uid/cr-failover-history.json"
}
""",
    )
)

INIT_SCRIPT = f"""#!/bin/sh /etc/rc.common
{BEGIN}
START=99
STOP=10
USE_PROCD=1

start_service() {{
    procd_open_instance
    procd_set_param command /bin/sh {PATH} loop
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}}

stop_service() {{
    {PATH} stop >/dev/null 2>&1
}}
{END}
"""

OVERWRITE_KEEP = f"""#!/bin/sh
. /usr/share/openclash/ruby.sh
. /usr/share/openclash/log.sh
. /lib/functions.sh

# ClashRemote debug session (2026-09-06)
# 抖音评论图 + 完美校园 加规则到 rules 段头部 (位置 0, 最高优先级)
# wv1.yaml rules 段用单引号格式，注入值必须也是单引号字符串

LOG_OUT "Tip: Start Running Custom Overwrite Scripts..."
LOGTIME=$(echo $(date "+%Y-%m-%d %H:%M:%S"))
LOG_FILE="/tmp/openclash.log"
CONFIG_FILE="$1"

ruby_arr_insert "$CONFIG_FILE" "['rules']" "0" "'- DOMAIN-KEYWORD,17wanxiao,DIRECT'"
ruby_arr_insert "$CONFIG_FILE" "['rules']" "0" "'- DOMAIN-SUFFIX,douyinpics.com,DIRECT'"

{BEGIN}
[ -x {INIT} ] && {INIT} start >/dev/null 2>&1
{END}
exit 0
"""

SSH_BASE = [
    "sshpass",
    "-e",
    "ssh",
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "ConnectTimeout=10",
    f"{USERNAME}@{HOST}",
]


def ssh(cmd: str, timeout: int = 60) -> str:
    env = os.environ.copy()
    env["SSHPASS"] = PASSWORD
    env.pop("http_proxy", None)
    env.pop("https_proxy", None)
    env.pop("HTTP_PROXY", None)
    env.pop("HTTPS_PROXY", None)
    env.pop("ALL_PROXY", None)
    p = subprocess.run(
        SSH_BASE + [cmd],
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
    )
    out = (p.stdout or "") + (p.stderr or "")
    # drop ssh banners
    lines = [
        ln
        for ln in out.splitlines()
        if "Warning: Permanently added" not in ln
        and "post-quantum" not in ln
        and "This session may be vulnerable" not in ln
        and "The server may need to be upgraded" not in ln
        and "openssh.com/pq" not in ln
    ]
    text = "\n".join(lines).strip()
    if p.returncode != 0:
        raise SystemExit(f"ssh 失败 ({p.returncode}): {text[-800:]}")
    return text


def scp_text(remote: str, contents: str):
    env = os.environ.copy()
    env["SSHPASS"] = PASSWORD
    env.pop("http_proxy", None)
    env.pop("https_proxy", None)
    env.pop("HTTP_PROXY", None)
    env.pop("HTTPS_PROXY", None)
    env.pop("ALL_PROXY", None)
    with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as f:
        f.write(contents)
        if not contents.endswith("\n"):
            f.write("\n")
        local = f.name
    try:
        p = subprocess.run(
            [
                "sshpass",
                "-e",
                "scp",
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                "UserKnownHostsFile=/dev/null",
                local,
                f"{USERNAME}@{HOST}:{remote}",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            env=env,
        )
        if p.returncode != 0:
            raise SystemExit("scp 失败: " + ((p.stderr or p.stdout)[-400:]))
    finally:
        os.unlink(local)


def main():
    print("SSH 登录", HOST, "…")
    print(ssh("uname -a | awk '{print $1,$2,$3}'"))
    secret = ssh("uci -q get openclash.config.dashboard_password").splitlines()[-1].strip()
    port = ssh("uci -q get openclash.config.cn_port").splitlines()[-1].strip() or "9090"
    if not secret:
        secret = PASSWORD
    print(f"Clash API {port}")
    page = PAGE_SRC.replace('const SECRET = "123456"', f'const SECRET = "{secret}"')
    conf = f"""PORT={port}
SECRET={secret}
INTERVAL={INTERVAL}
ENABLED={ENABLED}
BATCH=4
DELAY_TIMEOUT=5000
CURL_MAX=7
"""
    ssh("mkdir -p /etc/openclash /usr/share/openclash/ui /var/run /tmp")
    print("写入脚本 / 面板 / init …")
    scp_text(PATH, SCRIPT)
    scp_text(CONF, conf)
    scp_text(INIT, INIT_SCRIPT)
    scp_text(f"{UI}/cr-failover.html", page)
    scp_text(OVERWRITE, OVERWRITE_KEEP)
    print(
        ssh(
            f"""
chmod 755 {PATH} {INIT} {OVERWRITE}
chmod 644 {UI}/cr-failover.html {CONF}
for d in {UI}/*; do
  [ -d "$d" ] || continue
  cp -f {UI}/cr-failover.html "$d/cr-failover.html"
done
{PATH} stop >/dev/null 2>&1 || true
{INIT} enable >/dev/null 2>&1 || true
{INIT} restart >/dev/null 2>&1 || true
sleep 1
if [ ! -f {PID} ] || ! [ -d /proc/$(cat {PID} 2>/dev/null) ]; then
  setsid /bin/sh {PATH} loop >/dev/null 2>&1 </dev/null &
  sleep 1
fi
echo INSTALLED=$(test -f {PATH} && echo yes || echo no)
echo PAGE=$(test -f {UI}/cr-failover.html && echo yes || echo no)
echo PAGE_BYTES=$(wc -c < {UI}/cr-failover.html)
if [ -f {PID} ]; then pid=$(cat {PID}); [ -d /proc/$pid ] && echo RUNNING=yes PID=$pid || echo RUNNING=no; else echo RUNNING=no; fi
ls /usr/share/openclash/ui/cr-failover.html /usr/share/openclash/ui/*/cr-failover.html 2>/dev/null
{PATH} once >/tmp/clashremote-once.out 2>&1 || true
echo '---ONCE---'
cat /tmp/clashremote-failover.status 2>/dev/null
echo '---LOG---'
tail -n 8 /tmp/clashremote-failover.log 2>/dev/null
"""
        )
    )
    print()
    print("浏览器打开：")
    print(f"  http://{HOST}:{port}/ui/cr-failover.html")


if __name__ == "__main__":
    main()
