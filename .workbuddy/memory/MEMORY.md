# ClashRemote 项目长期记忆

## 构建
- **swift build 必须加 `--disable-sandbox`**：WorkBuddy 会话 Bash 在内核 sandbox 里，
  sandbox_exec() 被禁，SwiftPM 编译 Package.swift manifest 时强制依赖它 → 不加此 flag 直接失败
  （报 `sandbox-exec: sandbox_apply: Operation not permitted`）。build.sh 里是 `swift build -c release
  --product ClashRemote`，没加 flag，在会话里跑不通——要么改 build.sh，要么内联命令加 flag。
- ditto/codesign/open/osascript 不调 sandbox-exec，dangerouslyDisableSandbox 下可写 /Applications 完成安装。
- 打包流程：见 build.sh（rm -rf dist → mkdir → cp 二进制+Info.plist+PkgInfo+AppIcon.icns → codesign ad-hoc）。
- **本机没有完整 Xcode，CLT 里没有 `XCTest.framework` → `swift test` 必定报 `no such module 'XCTest'`**
  （CLT 只有 `Testing.framework` = swift-testing）。Tests/ 下的 XCTest 用例在本机从来跑不起来，不是代码问题。
- **没有 XCTest 时怎么验证逻辑**（实测有效）：`swiftc -O` 挑依赖最小的源文件组（LocalProfile.swift /
  Models.swift / NodeFailoverScript.swift 只依赖 Foundation）**加一份自己写的 `/tmp/main.swift` 断言主程序**，
  缺的小工具（JSONValue）从 HTTPClient.swift 抄个最小副本一起编；再把生成的 shell 脚本导出到 /tmp，
  用 `sh -n` 查语法、`awk '/^cmd=/{exit}{print}'` 抽出函数定义 `.` 进来真跑函数做行为断言。
- **改 LocalProfile 字段必须同时改手写的 `init(from:)`**（`decodeIfPresent ?? 默认`）。合成解码在缺字段时
  会整体抛错 → 用户的 profile.json 会被静默丢回 default。可用本机真实的 profile.json 直接验证。

## 网络架构
- HTTPClient 用 URLSession(ephemeral + connectionProxyDictionary=[:]) 强制不走系统代理直连内网路由器，
  + NoRedirectDelegate 禁止 follow 3xx（luciLogin 的 302 带 sysauth cookie 必须原样返回）。
  原 DirectHTTP.swift（NWConnection 裸 TCP）已弃用保留不引用——裸 TCP 在 ad-hoc 重签后本地网络
  权限/边界不可靠。
- 路由器 192.168.10.1（Rax3000M / OpenClash）：LuCI ubus login 用 root/password；
  响应都是 Transfer-Encoding: chunked。
- **发现 macOS 本地网络权限状态的可读文件**：`/Library/Preferences/com.apple.networkextension.plist`
  （root:wheel 但 **world-readable**）。它是 `NSKeyedArchiver` 归档，`plutil -p` 后每个记录对象里有
  `SigningIdentifier` / `Path` / `MulticastPreferenceSet` / `DenyMulticast`。
  **已授权 = MulticastPreferenceSet=true 且 DenyMulticast=false**。这比去点系统设置快得多，
  也能直接看出"同一 bundle id 出现多条重复记录"（ad-hoc 重签 + 换安装路径会产生多条）。
  ⚠️ 解析时两种值形态都要处理：`Path` / `SigningIdentifier` 是 **UID 引用**
  （`<CFKeyedArchiverUID ...>{value = 354}`，要靠 `354 => "字符串"` 表解引用），
  而 `MulticastPreferenceSet` / `DenyMulticast` 是**直接布尔值**（`=> true`）—— 只按 UID 解析会把它们读成 None。
  实测本机有 2 条 `dev.don.ClashRemote` 记录（dist 路径一条、/Applications 一条），都是已授权。
  注意：`tccutil` **不支持** LocalNetwork；彻底清空要在 Recovery 模式删
  `/Volumes/Data/Library/Preferences/com.apple.networkextension{,.uuidcache}.plist`。
- LAN 排查顺序：先 curl/nc 直连 → 再同构 Swift 复现 → 两者都好就说明是 app 进程侧问题 → 查上面的 plist。

## 功能模型
- 节点页只选一个当前节点给所有 App 共用（旧的 Emby/AppleIntelligence/Senplayer 独立策略组
  均已清理删除——SenplayerPolicy.swift 已删，相关 UI/逻辑全部移除）。
- OpenClashService 的 rewriteRuleLines 仍用字面量清理路由器配置里残留的 Senplayer 标记块
  （# ClashRemote: Senplayer），避免旧配置残留影响，但这只是清理逻辑，不再生成新功能。
- 普通规则（直连/拒绝/全局）用 runAcrossDevices 同步所有路由器（统一规则）。
- **拉黑节点（黑名单）**：`profile.blockedNodes`（精确名）+ `profile.blockedKeywords`（关键词，整订阅/机场）。
  关键区分：`isBlocked`（用户拉黑）/ `isFilteredOut`（关键词+地区+白名单，展示层隐藏）/ `shouldExcludeNode`（= 并集，自动切换用）。
  **拉黑的节点仍显示在节点列表里（灰掉、可解除），只约束自动换节点**。改这块时三者的分工不能混。
  `evaluateFailover` 里 `leafBlocked` 会跳过所有"保持现状"分支（阈值内/复核为通/抖动保护）。
- **固定当前节点**：`profile.pinnedNode` → `effectiveFailoverThreshold` 归零（只超时才换）。
  设备端 conf 里是 `PIN_MODE=1`，**阈值原值仍保留**（关掉固定要能恢复）。
  **⚠️ 浏览器守护面板（cr-failover.html）是纯静态页，写不了路由器 conf** —— 所以面板上的"固定"
  走的是**「谁手动改了节点就固定谁」**：脚本用 `PINFILE` 记「自己选定的节点」，当前 leaf 与它不一致
  = 别处改的（面板点节点 / App 手动选）→ 固定住不动，直到该节点超时。脚本自己换完会更新 PINFILE
  所以不会误判；`loop()` 启动时会 `rm -f "$PINFILE"` 重置基线。
  `cr-failover.json` 里的 `pinMode`/`pin`/`auto` 三个字段给面板读，面板的「恢复自动」= PUT 回 `auto`。

## 设备与插件模型
- 两台设备（`~/Library/Application Support/ClashRemote/devices.json`）：
  - **Rax3000M** OpenClash，`192.168.10.1:80`，root/password（旧网段，换网后会超时）
  - **ZTE U30Pro** 猫猫，`192.168.0.1:2333`，admin/admin（UFI-TOOLS 后台）
- 换网段后**旧设备条目会变成超时源**：192.168.10.1 不在 192.168.0.0/24 里，走默认网关被丢包
  → `NSURLErrorTimedOut`；`runAcrossDevices` 会挨个连，卡在废设备上。
- **ZTE U30Pro = Android 内核的 5G CPE**，UFI-TOOLS 是 `com.minikano.f50_sms`，
  Ktor/0.0 服务在 2333；root shell 靠 `/data/data/com.minikano.f50_sms/files/kano_root_shell.sock`。
  UFI web UI 是 SPA（`/script/main.js` 1.69MB，里面没有 clash/订阅字样）；
  插件机制是 `<!-- [KANO_PLUGIN_START] xxx.js -->` 包裹的注入脚本（见 `ufi-failover-plugin.esc`）。
- **⚠️ UFI 的 Ktor 服务端在长命令执行期间会整体阻塞**（实测长命令跑着时 `GET /` 直接超时），
  所以并发请求会得到 -1001 而不是 -1004。长命令：`Clash.Service restart`、
  `downloadSubscription`(120s)、`runDeviceFailoverOnce`(40s)。
- **猫猫插件的配置模型（和 OpenClash 完全不同）**：
  - `/data/clash/Proxy/config.yaml` = **完整 mihomo 配置**（`cmfa-plugin`/`external-ui`/`ntp`/
    `tproxy-port`/`keep-alive-*`，像 CMFA 模板），节点是**内联 `proxies:`**，
    `proxy-groups` **逐个枚举节点名**；**没有 `proxy-providers` / `use:` / `include-all`**。
  - `Proxy/proxies/*.yaml`（渔云.yaml / provider1.yaml / provider2.yaml）都是**完整配置**，
    不是节点列表。
  - 运行时：`external-controller: 0.0.0.0:7788`，`secret: "123456"`，mixed-port 7890，tproxy-port 7893。
  - 启停：`/data/clash/Scripts/Clash.Service {start|stop}` → 转发给 `clashctl_arm64`（Go）。
    clashctl 也是校验配置的那一方，报错形如 `空文件, 插件已停止运行`（配置被写残就起不来）。
- **不要用 ClashRemote 的「订阅」tab 去管猫猫**：它往 config.yaml 插 `proxy-providers`，
  而猫猫的配置是插件生成的完整配置（内联节点）。模型不匹配，写下去不生效甚至写坏。

## 测速 / 自动换节点（2026-09-30 重写）
- **必须用内核的整组测速**：`GET /group/{组名}/delay?timeout=N&url=…`（`ClashBackend.testGroupDelay`）。
  一个请求测完整组、内核侧并发、耗时 ≈ timeout；**只返回测通的节点，没测通的键完全不出现**
  → `缺失 = 超时`（已用 `/proxies` 的 `history.delay==0` 交叉验证）。
  逐个 `/proxies/{name}/delay` 是**超时驱动**的：死节点必然等满 timeout，分批并发时整批等最慢的那个
  → 85 个节点实测 50~70s，这就是"全部测速很慢 / 半天不换节点"的根因。换成整组测速后：一次请求 ~3-4s。
- App 侧常量（AppState）：单节点/整组超时都 3s、切换回差 40ms、逐个兜底上限 24 个。
  **超时（delay<=0）必须换**；只是"慢"的话要求新节点快 40ms 以上，避免两个健康节点互相跳。
- `evaluateFailover` 是唯一决策入口：`manual=true` 时不受「自动换节点」开关限制（用户明确点击就该生效），
  并且每个提前 return 都要给出 notice，别再静默失败。整组测速里当前节点是通的就当成抖动、不换。
- 「全部测速」跑完会**立刻**拿这批结果评估一次并传 `preMeasured`，不等下一个周期。
- 垃圾"信息节点"（`剩余流量：…`/`套餐到期：…`/`节点超时请手动更新订阅`）**测速真的通**（119~152ms），
  只能按名字关键词排除 → 设备脚本 `NodeFailoverScript` 加了内置兜底词表 `ALWAYS_EXCLUDE_KEYWORDS`
  （不依赖 conf，因为旧版安装的 conf 里没有 EXCLUDE_* 字段）。
- ⚠️ 猫猫的 `preferredPolicyGroup()` 会解析到 **`漏网之鱼`**（候选表里写的是"节点选择"，
  而组名其实叫 **`选择节点`**），靠 漏网之鱼→选择节点 的嵌套才拿到正确的叶子；改这块要小心。
- 轮询开销：订阅列表只在 `refresh(full:true)` 时读（猫猫读它要走 UFI root shell）；
  设备守护状态 3s → 15s 一次；测速/换节点期间不让轮询覆盖 `snapshot.groups`（否则会冲掉乐观更新）。
- ⚠️ **设备守护装在路由器上的是旧脚本 + 旧 conf**：改完 `NodeFailoverScript` 后必须在「控制」里
  重新安装，才会把新的 conf（含 profile 的阈值/关键词/地区）推上去。
- 客户端先 `addingPercentEncoding` 再塞 `URLComponents.path` 会双重编码（`%`→`%25`）。mihomo 宽容
  （实测 200），但新代码直接传原始中文名，别依赖这个行为。

## 会话沙箱限制
- log show / 读 TCC.db / 读系统日志均被沙箱拦，无法查 app 运行时错误——只能靠 curl 验证网络可达性
  + 读代码静态分析定位。
