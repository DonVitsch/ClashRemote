import Foundation

enum OpenClashFailover {
    static let path = "/etc/openclash/clashremote-failover.sh"
    static let confPath = "/etc/openclash/clashremote-failover.conf"
    static let pidPath = "/var/run/clashremote-failover.pid"
    static let statusPath = "/tmp/clashremote-failover.status"
    static let logPath = "/tmp/clashremote-failover.log"
    static let historyPath = "/etc/openclash/clashremote-failover.history"
    /// 记「脚本自己选定的节点」，用来识别别人手动改了节点（手动改了 = 固定住不动）。
    static let pinPath = "/etc/openclash/clashremote-failover.pin"
    static let initPath = "/etc/init.d/clashremote-failover"
    static let overwritePath = "/etc/openclash/custom/openclash_custom_overwrite.sh"
    static let markerBegin = "# --- clashremote-node-failover begin ---"
    static let markerEnd = "# --- clashremote-node-failover end ---"

    static var source: String {
        NodeFailoverScript.source
            .replacingOccurrences(of: "#!/system/bin/sh", with: "#!/bin/sh")
            .replacingOccurrences(
                of: "export PATH=\"/data/data/com.minikano.f50_sms/files:/system/bin:/system/xbin:${PATH:-}\"",
                with: "export PATH=\"/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}\""
            )
            .replacingOccurrences(of: "/data/clash/Scripts/node-failover.conf", with: confPath)
            .replacingOccurrences(of: "/data/clash/Scripts/node-failover.pid", with: pidPath)
            .replacingOccurrences(of: "/data/clash/Scripts/node-failover.log", with: logPath)
            .replacingOccurrences(of: "/data/clash/Scripts/node-failover.status", with: statusPath)
            .replacingOccurrences(of: "/data/clash/Proxy/WebUI/zashboard/cr-failover.json", with: "/tmp/clashremote-failover.json")
            .replacingOccurrences(of: "/data/clash/Scripts/node-failover.history", with: historyPath)
            .replacingOccurrences(of: "/data/clash/Scripts/node-failover.pin", with: pinPath)
            .replacingOccurrences(of: "/data/clash/Proxy/WebUI/zashboard/cr-failover-history.json", with: "/tmp/clashremote-failover-history.json")
            .replacingOccurrences(of: "/data/clash/Scripts/node-failover.tmp", with: "/tmp/clashremote-failover.tmp")
            .replacingOccurrences(of: "PORT=7788", with: "PORT=9090")
            .replacingOccurrences(
                of: "for c in /data/data/com.minikano.f50_sms/files/curl /system/bin/curl curl; do",
                with: "for c in /usr/bin/curl /bin/curl curl; do"
            )
            .replacingOccurrences(
                of: "have() {",
                with: """
                resolve_ui() {
                    if [ -d /usr/share/openclash/ui ]; then
                        echo /usr/share/openclash/ui
                        return
                    fi
                    echo /tmp
                }
                have() {
                """
            )
            .replacingOccurrences(
                of: """
                    [ -n "$SECRET" ] || SECRET=123456
                }
                """,
                with: """
                    [ -n "$SECRET" ] || SECRET=123456
                    uid=$(resolve_ui)
                    JSONFILE="$uid/cr-failover.json"
                    HISTJSON="$uid/cr-failover-history.json"
                }
                """
            )
    }

    static var pageTemplate: String {
        let installedURL = Bundle.main.resourceURL?
            .appendingPathComponent("ClashRemote_ClashRemote.bundle/cr-failover.html")
        if let url = installedURL ?? Bundle.module.url(forResource: "cr-failover", withExtension: "html"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.replacingOccurrences(of: "const SECRET = \"123456\"", with: "const SECRET = \"__CLASH_SECRET__\"")
        }
        return ""
    }

    static func conf(secret: String, port: Int, interval: Int, enabled: Bool, profile: LocalProfile) -> String {
        let seconds = max(interval, 5)
        let on = enabled ? 1 : 0
        let listen = port > 0 ? port : 9090
        return """
        PORT=\(listen)
        SECRET=\(NodeFailoverScript.shellQuoted(secret))
        INTERVAL=\(seconds)
        ENABLED=\(on)
        BATCH=12
        DELAY_TIMEOUT=4000
        CURL_MAX=7
        \(NodeFailoverScript.profileConf(profile))
        """
    }

    static let initScript = """
    #!/bin/sh /etc/rc.common
    \(markerBegin)
    START=99
    STOP=10
    USE_PROCD=1

    start_service() {
        procd_open_instance
        procd_set_param command /bin/sh \(path) loop
        procd_set_param respawn 3600 5 0
        procd_set_param stdout 1
        procd_set_param stderr 1
        procd_close_instance
    }

    stop_service() {
        \(path) stop >/dev/null 2>&1
    }
    \(markerEnd)
    """

    static let startCommand = """
    mkdir -p /etc/openclash /var/run /tmp
    chmod 755 \(path) \(initPath)
    \(path) stop >/dev/null 2>&1
    /etc/init.d/clashremote-failover enable >/dev/null 2>&1
    /etc/init.d/clashremote-failover restart >/dev/null 2>&1
    sleep 1
    if [ -f \(pidPath) ]; then pid=$(cat \(pidPath)); [ -d /proc/$pid ] && echo started && exit 0; fi
    /bin/sh \(path) loop >/dev/null 2>&1 &
    sleep 1
    if [ -f \(pidPath) ]; then pid=$(cat \(pidPath)); [ -d /proc/$pid ] && echo started && exit 0; fi
    echo failed
    """

    static func mergeOverwrite(_ existing: String, interval: Int, enabled: Bool, profile: LocalProfile) -> String {
        let stripped = stripHook(existing)
        let base = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = base.isEmpty ? defaultOverwriteHeader : base
        return body + "\n\n" + hookBlock(interval: interval, enabled: enabled, profile: profile) + "\n"
    }

    static func stripHook(_ existing: String) -> String {
        guard let begin = existing.range(of: markerBegin) else { return existing }
        let pre = String(existing[..<begin.lowerBound])
        let rest = String(existing[begin.lowerBound...])
        if let end = rest.range(of: markerEnd) {
            return pre + String(rest[end.upperBound...])
        }
        return pre
    }

    static func hookInstalled(in text: String) -> Bool {
        text.contains(markerBegin)
    }

    private static let defaultOverwriteHeader = """
    #!/bin/sh
    . /usr/share/openclash/ruby.sh
    . /usr/share/openclash/log.sh
    . /lib/functions.sh
    CONFIG_FILE="$1"
    """

    static func hookBlock(interval: Int, enabled: Bool, profile: LocalProfile) -> String {
        let seconds = max(interval, 5)
        let on = enabled ? 1 : 0
        return """
        \(markerBegin)
        # Clash Remote: write files in-process. A background subshell gets killed when OpenClash start ends.
        mkdir -p /etc/openclash /usr/share/openclash/ui /var/run /tmp
        cat > \(path) << 'CR_FAILOVER_EOF'
        \(source)
        CR_FAILOVER_EOF
        cat > \(initPath) << 'CR_FAILOVER_INIT_EOF'
        \(initScript)
        CR_FAILOVER_INIT_EOF
        PORT=$(uci -q get openclash.config.cn_port)
        SECRET=$(uci -q get openclash.config.dashboard_password)
        [ -n "$PORT" ] || PORT=9090
        [ -n "$SECRET" ] || SECRET=password
        SECRET_B64=$(printf '%s' "$SECRET" | base64 | tr -d '\\n')
        cat > \(confPath) << EOF
        PORT=$PORT
        SECRET_B64=$SECRET_B64
        INTERVAL=\(seconds)
        ENABLED=\(on)
        BATCH=12
        DELAY_TIMEOUT=4000
        CURL_MAX=7
        EOF
        cat >> \(confPath) << 'CR_FAILOVER_PROFILE_EOF'
        \(NodeFailoverScript.profileConf(profile))
        CR_FAILOVER_PROFILE_EOF
        chmod 755 \(path) \(initPath)
        PAGE_IN=/tmp/cr-failover.html.in
        cat > "$PAGE_IN" << 'CR_FAILOVER_PAGE_EOF'
        \(pageTemplate)
        CR_FAILOVER_PAGE_EOF
        SECRET_ESC=$(printf '%s' "$SECRET" | sed 's/[&|#\\\\]/\\\\&/g')
        UI=/usr/share/openclash/ui
        mkdir -p "$UI"
        sed "s#__CLASH_SECRET__#${SECRET_ESC}#g" "$PAGE_IN" > "$UI/cr-failover.html"
        chmod 644 "$UI/cr-failover.html" 2>/dev/null
        for d in "$UI"/*; do
          [ -d "$d" ] || continue
          cp -f "$UI/cr-failover.html" "$d/cr-failover.html" 2>/dev/null
        done
        /etc/init.d/clashremote-failover enable >/dev/null 2>&1
        if [ ! -f \(pidPath) ] || ! [ -d /proc/$(cat \(pidPath) 2>/dev/null) ]; then
          /etc/init.d/clashremote-failover restart >/dev/null 2>&1
          setsid /bin/sh \(path) loop >/dev/null 2>&1 </dev/null &
        fi
        \(markerEnd)
        """
    }
}
