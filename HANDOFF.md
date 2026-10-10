# HANDOFF.md — ClashRemote 项目交接文档

> 生成时间：2026-09-27
> 上一个 Agent：Claude Opus 4.7 (Claude Code)
> 当前状态：**编译失败**（1 个错误，见下方"已知问题"）

---

## 1. 项目整体架构

ClashRemote 是一个 macOS SwiftUI 桌面应用（Swift Package Manager 构建），用于远程控制两台路由器上的 Clash 代理插件：

| 路由器 | 插件 | 连接方式 |
|--------|------|----------|
| rax300m | OpenClash | LuCI HTTP API + UCI + Clash RESTful API |
| u30p | 猫猫 (mihomo) | UFI root shell + Clash RESTful API |

**核心约束**：同一时间只能连接一台路由器，不能同时操控两台。

### 目录结构

```
Sources/ClashRemote/
├── App/
│   ├── ClashRemoteApp.swift          # @main 入口
│   └── AppState.swift                # 全局状态（@Observable）
├── Models/
│   ├── Models.swift                  # RouterDevice, ProxyGroup, ProxyItem, Subscription 等
│   └── LocalProfile.swift            # [新建] 本地配置数据模型
├── Store/
│   ├── DeviceStore.swift             # 路由器设备列表持久化 → devices.json
│   └── ProfileStore.swift            # [新建] 本地配置持久化 → profile.json
├── Network/
│   ├── ClashBackend.swift            # 协议定义
│   ├── OpenClashService.swift        # OpenClash 实现（含 SimplePolicyYAML）
│   ├── MaoMaoService.swift           # 猫猫实现
│   ├── OpenClashClient.swift         # LuCI/UCI HTTP 封装
│   ├── UFIClient.swift               # UFI root shell 封装
│   ├── HTTPClient.swift              # 基础 HTTP 客户端
│   ├── DirectHTTP.swift              # 直连 HTTP
│   ├── NodeFailoverScript.swift      # 设备端 shell 故障转移脚本
│   ├── OpenClashFailover.swift       # OpenClash 端故障转移
│   ├── DomainRulePolicy.swift        # 域名规则匹配
│   └── DomesticDirectPolicy.swift    # 大陆直连规则
└── Views/
    ├── RootView.swift                # NavigationSplitView：侧栏设备列表 + 右侧面板
    ├── DashboardView.swift           # 主面板（控制/订阅/节点/规则 四个 tab）
    └── NodesBoard.swift              # 节点网格卡片视图
```

### 关键设计模式

- **状态管理**：`AppState` 是唯一的状态中心，用 `@Observable` + `@Environment` 传递
- **后端抽象**：`ClashBackend` 协议统一 OpenClash 和猫猫的接口
- **持久化**：`~/Library/Application Support/ClashRemote/` 目录下的 JSON 文件
  - `devices.json`：路由器列表（已有）
  - `profile.json`：本地配置（新增）
- **配置重写**：`SimplePolicyYAML.rewrite()` 把路由器配置文件中的多个策略组收成单一「节点选择」组，并用 `filter` 正则排除垃圾节点
- **故障转移**：
  - **本机端**：`AppState.failoverAfterTimeout()` 周期检测当前节点，超时后测全部候选节点并切换
  - **设备端**：`NodeFailoverScript` 生成 shell 脚本安装到路由器上独立运行

### UI 当前结构

```
RootView (NavigationSplitView)
├── 侧栏：设备列表 + 添加/编辑/删除路由器
└── 右侧 DashboardView
    ├── header：设备状态 + 流量 + 启停重启按钮
    ├── tab picker (segmented)：控制 / 订阅 / 节点 / 规则
    ├── controlTab：代理模式、流量接管、设备守护、开关、配置文件
    ├── subscribeTab：路由器上的订阅列表
    ├── nodesTab → NodesBoard：节点卡片网格 + 测速 + 自动切换
    └── rulesTab：规则列表 + 添加规则 + 测试规则
```

---

## 2. 完整需求目标

用户有 4 个需求：

### 需求 1：本地配置模块

**目的**：用户在两台路由器之间来回切换时，订阅链接、节点过滤规则、域名分流规则需要保持一致。当前这些配置都直接存在路由器上，切换后需要手动重配。

**方案**：创建一个本地配置模块（`LocalProfile`），在 App 内管理以下内容：
- 订阅链接（名称 + URL + UA）
- 节点过滤关键词（如"官网"、"到期"等，命中则隐藏+排除）
- 地区排除（如香港、中国大陆-不含台湾）
- 机场白名单（如只保留"乌拉VPN"和"渔云"）
- 域名分流规则（如 DOMAIN-SUFFIX,douyin.com,DIRECT）
- 自动切换延迟阈值

连接路由器后可一键同步这些设置。

### 需求 2：删除 HK 和中国节点（不含台湾）

将此功能做成**可配置的地区排除**，在 UI 上提供 Toggle 开关。当用户启用"香港"和"中国大陆"排除后：
- 节点列表不再显示这些节点
- 自动切换时不会切到这些节点
- 中国大陆排除明确**不包含台湾**

### 需求 3：只保留乌拉 VPN 和渔云

做成**机场白名单**功能。启用白名单后，只有节点名称中包含白名单关键词的节点会被保留，其他机场的节点全部过滤。

### 需求 4：自动切换延迟阈值

当前逻辑：节点 ping 通（delay > 0）就不切换，只在超时时才切换。

新逻辑：如果当前节点延迟 < 180ms，不切换；如果延迟 >= 180ms 或超时，则切换到延迟更低的节点。阈值 180ms 可在 UI 中调整。

### UI 要求

用户明确要求：**界面要适用于新手操作，要傻瓜式一点，操作更合理更直观**。需要对整个界面进行大改。

---

## 3. 已完成的功能

### 需求 4：自动切换延迟阈值 ✅ 完成

`AppState.failoverAfterTimeout()` 已修改：
- 新增 `profile.failoverThreshold`（默认 180ms）
- 当 `delay > 0 && delay < threshold` 时不切换
- 当 `threshold <= 0` 时禁用阈值功能（退回原逻辑：只在超时时切换）
- 当 `delay >= threshold` 时，fall through 到候选节点查找逻辑

### 节点过滤核心逻辑 ✅ 完成

- `LocalProfile.shouldExcludeNode(_:)` 统一过滤方法（关键词 + 地区 + 白名单）
- `AppState.failoverCandidates()` 已改用 `profile.shouldExcludeNode()` 替代硬编码的 `isHongKongName()`
- 故障转移候选节点筛选已改用 `profile.shouldExcludeNode()` 替代硬编码的 `isHongKongName()`

### 动态 nodeFilter ✅ 完成

- `SimplePolicyYAML.nodeFilter` 从静态常量改为 `defaultNodeFilter`
- `SimplePolicyYAML.rewrite()` 接受可选 `nodeFilter` 参数
- `ClashBackend` 协议的 `flattenPolicyGroups` 签名已更新为 `(configPath: String, nodeFilter: String?)`
- `OpenClashService` 和 `MaoMaoService` 均已更新
- `AppState` 中所有调用 `flattenPolicyGroups` 的地方都已传入 `profile.nodeFilterRegex()`

### 同步方法 ✅ 完成

`AppState` 新增以下方法：
- `syncSubscriptionsToRouter()` — 同步本地订阅到当前路由器
- `syncDomainRulesToAllRouters()` — 同步域名规则到所有路由器
- `syncFilterToRouter()` — 同步过滤规则到当前路由器
- `syncAllToRouter()` — 一键同步所有设置

---

## 4. 已修改文件详情

### 新建文件

| 文件 | 内容 |
|------|------|
| `Models/LocalProfile.swift` | `LocalProfile` 结构体（subscriptions, filterKeywords, regionExclusions, providerWhitelist, providerWhitelistEnabled, domainRules, failoverThreshold）+ `LocalSubscription` + `RegionExclusion` 枚举（hongkong/china/japan/usa/singapore，含 `matches()` 匹配方法）+ `LocalDomainRule` + `shouldExcludeNode()` + `nodeFilterRegex()` |
| `Store/ProfileStore.swift` | 仿 `DeviceStore` 模式，读写 `~/Library/Application Support/ClashRemote/profile.json` |

### 修改文件

| 文件 | 修改内容 |
|------|----------|
| `App/AppState.swift` | 1) 添加 `profileStore` 和 `profile` 属性，`init()` 中加载 profile，添加 `persistProfile()` 方法；2) `failoverAfterTimeout()` 加入 180ms 阈值判断；3) `failoverCandidates()` 中 `isHongKongName` → `profile.shouldExcludeNode()`；4) 候选节点过滤中 `isHongKongName` → `profile.shouldExcludeNode()`；5) `switchConfig`/`updateSubscription`/`saveSubscription`/`restorePolicyTweaks` 传入 `profile.nodeFilterRegex()`；6) 新增 `syncSubscriptionsToRouter`/`syncDomainRulesToAllRouters`/`syncFilterToRouter`/`syncAllToRouter` 方法 |
| `Network/ClashBackend.swift` | `flattenPolicyGroups` 签名从 `(configPath: String)` 改为 `(configPath: String, nodeFilter: String?)` |
| `Network/OpenClashService.swift` | 1) `flattenPolicyGroups` 签名加 `nodeFilter` 参数；2) `SimplePolicyYAML.nodeFilter` → `defaultNodeFilter`；3) `rewrite()` 加 `nodeFilter` 参数，内部用 `filter` 局部变量 |
| `Network/MaoMaoService.swift` | `flattenPolicyGroups` 签名加 `nodeFilter` 参数 |
| `Views/NodesBoard.swift` | 1) `displayGroups` 计算属性调用改为 `build(from:mode:profile:)`；2) `NodeBoardLayout.build()` 签名加 `profile` 参数；3) global 分支的 `flattenLeaves` 调用加了 `profile:` 参数 |

---

## 5. 未完成的功能

### 5.1 NodesBoard.swift 改造（改了一半）

`NodeBoardLayout` 中：
- `flattenLeaves()` 签名还没加 `profile` 参数（**这是当前编译错误的原因**）
- `build()` 的 rule 分支（第 479 行）调用 `flattenLeaves` 时没传 `profile`
- `isJunkNode()` 还是硬编码的旧版本，需要改为使用 `profile.shouldExcludeNode()`

### 5.2 ProfileTab UI（完全没做）

需要新建 `Views/ProfileTab.swift`（或直接写在 DashboardView 中），包含：
- **订阅管理卡片**：增删改本地订阅（名称、URL、UA、启用/停用）
- **节点过滤关键词卡片**：增删关键词，如"官网"、"到期"、"故障转移"等
- **地区排除卡片**：每个 `RegionExclusion` 一个 Toggle（香港、中国大陆-不含台湾、日本、美国、新加坡）
- **机场白名单卡片**：Toggle 启用 + 白名单列表增删（预设"乌拉"和"渔云"）
- **自动切换阈值卡片**：Stepper/Slider 设置 `failoverThreshold`（0-500ms）
- **域名规则卡片**：增删域名规则（域名 + DOMAIN-SUFFIX/DOMAIN-KEYWORD + DIRECT/REJECT/GLOBAL）
- **同步操作卡片**：同步订阅/同步规则/一键同步全部 按钮

### 5.3 DashboardView.swift 加新 tab

`MainTab` 枚举需要加一个 `.profile = "本地配置"` case，body 的 switch 加对应分支。

### 5.4 UI 大改（完全没做）

用户明确要求"画面要适用于新手操作，要傻瓜式一点，重新大改做一下界面 UI，让操作更合理更直观"。当前 UI 是给熟悉 Clash 的人设计的，需要重新设计整体布局使其对新手友好。这个要求的范围比较大，可能包括：
- 更清晰的导航和信息层级
- 更大的操作按钮和更明确的文字标签
- 预设配置（一键启用推荐设置）
- 减少专业术语，用通俗描述
- 操作引导和状态反馈

### 5.5 NodeFailoverScript.swift 设备端脚本（完全没做）

当前设备端 shell 脚本 `is_junk_name()` 和 `is_hongkong()` 是硬编码的。需要：
- `conf()` 方法接收 `LocalProfile`（或等价参数），生成 `EXCLUDE_KEYWORDS`、`EXCLUDE_REGIONS`、`PROVIDER_WHITELIST` 等变量写入配置文件
- 脚本中的 `collect_leaves` 函数使用这些变量过滤
- 或者更简单的方案：在 `conf()` 生成的配置文件中加入排除列表，脚本中读取

---

## 6. 已知问题 / 编译错误

### 编译错误（1 个）

```
NodesBoard.swift:464:99: error: extra argument 'profile' in call
```

**原因**：`NodeBoardLayout.build()` 在 global 分支调用了 `flattenLeaves(..., profile: profile)`，但 `flattenLeaves` 的签名还没有加 `profile` 参数。

**修复方法**：
1. 修改 `flattenLeaves` 签名，加 `profile: LocalProfile` 参数
2. 修改 `build()` 的 rule 分支（第 479 行），也传入 `profile`
3. 在 `flattenLeaves` 内部用 `profile.shouldExcludeNode()` 替代 `isJunkNode()`

### 潜在问题

- `isJunkNode()` 和 `isDomesticAlias()` 在修改后可能变成死代码，可以删除
- `isHongKongName()` 在 `AppState` 中可能也变成了死代码（failover 已改用 `profile.shouldExcludeNode`），但需要确认 NodesBoard 的 `sections()` 方法还在用 `NodeRegion.of()` 做地区分栏展示
- `profile` 属性没有标 `@ObservationIgnored`，所以修改 profile 会触发 UI 刷新——这是期望行为

---

## 7. 下一步应该做什么

按优先级排列：

### 第一步：修复编译错误

修改 `Views/NodesBoard.swift` 中的 `NodeBoardLayout`:
1. `flattenLeaves` 签名加 `profile: LocalProfile` 参数
2. 内部的 `isJunkNode(item.name)` 改为 `profile.shouldExcludeNode(item.name)`
3. `build()` 中 rule 分支的 `flattenLeaves` 调用加 `profile` 参数
4. 运行 `swift build` 确认编译通过

### 第二步：创建 ProfileTab UI

新建 `Views/ProfileTab.swift`，包含上述 5.2 节描述的所有卡片。复用 `DashboardView.swift` 中已有的 `Card` 组件。所有编辑操作完成后调用 `state.persistProfile()`。

### 第三步：DashboardView 加 tab

在 `DashboardView.MainTab` 枚举加 `.profile = "本地配置"`，在 body switch 加对应 case。

### 第四步：UI 大改（用户强调的重点）

用户说"画面一定要适用于新手操作，要傻瓜式一点，重新大改做一下界面 UI，让操作更合理更直观"。这需要重新审视整个 UI 布局，可能的方向：
- 侧栏加"本地配置"入口，独立于路由器连接状态
- 同步操作做成一键大按钮，状态清晰
- 过滤规则用预设模板（如"只保留乌拉+渔云"一键设置）
- 自动切换设置简化为开关+一个阈值输入

### 第五步：更新 NodeFailoverScript

让设备端脚本也使用 profile 中的过滤规则。

### 第六步：测试

运行 app，连接路由器验证：
- 本地配置的增删改查和持久化
- 过滤规则对节点列表和自动切换的影响
- 同步操作是否正确推送到路由器
- failover 阈值是否生效

---

## 8. 重要上下文（容易被忽略的）

### 关于 `SimplePolicyYAML.rewrite()` 和 nodeFilter

这个方法会**重写路由器上的 Clash 配置文件**，把多个策略组合并成一个「节点选择」组，并用 `filter` 正则过滤节点。`nodeFilter` 只能过滤**关键词**（因为 Clash 的 filter 只支持正则），地区排除和机场白名单只能在 App 端（显示+故障转移）做，写不进 YAML filter。

### 关于 `shouldExcludeNode` 的使用位置

这个方法在两个地方被调用：
1. `AppState`：故障转移候选节点筛选
2. `NodeBoardLayout`：节点列表显示过滤

两处逻辑必须一致（都使用 `LocalProfile.shouldExcludeNode()`），否则用户在界面上看到一个节点但自动切换不到它（或反过来）。

### 关于 `isDirectOrDomesticName()` 的保留

这个方法**没有被删除也不应该被删除**。它是 failover 的第一道防线（排除直连/大陆/占位节点），`shouldExcludeNode` 是第二道（用户自定义的排除规则）。两者是 AND 关系，不是替代关系。

### 关于机场白名单的匹配方式

`providerWhitelist` 使用 `localizedCaseInsensitiveContains` 做子串匹配。机场节点名通常格式为 `[01] 乌拉VPN 美国 1` 或 `渔云-新加坡-01`，所以白名单填"乌拉"和"渔云"就够了（不需要完整名称）。

### 关于中国大陆排除不含台湾

`RegionExclusion.china` 的 `matches()` 方法中明确做了台湾排除：先检测中国关键词（中国/🇨🇳/china/shanghai/beijing 等），再检测台湾关键词（台湾/🇹🇼/taiwan/taipei），只有匹配中国且不匹配台湾时才返回 true。

### 关于设备端脚本的独立性

`NodeFailoverScript.source` 是一个完整的 shell 脚本，部署到路由器后**独立运行**，不依赖 Mac App。它有自己的 `is_junk_name()` 和 `is_hongkong()` 函数。修改 App 端的 profile 不会自动更新设备端脚本——用户需要手动"重新安装"设备守护。

### 关于现有的 Card 和 ModeButton 组件

`DashboardView.swift` 中定义了可复用的视图组件：
- `Card(title:subtitle:content:)` — 带标题的卡片容器
- `ModeButton(title:selected:action:)` — 模式选择按钮
- `ToggleCard(title:isOn:)` — 带开关的卡片
- `SubscriptionEditor` — 订阅编辑 sheet
- `StatusPill` — 状态胶囊

新 UI 应该复用这些组件而不是重新造。

### 关于 `@Observable` 和 profile 变更

`AppState.profile` 没有标 `@ObservationIgnored`，所以对 `profile` 的任何修改都会触发依赖它的 SwiftUI 视图重新渲染。这是期望的行为——当用户在 ProfileTab 修改过滤规则时，NodesBoard 的节点列表应该实时更新。

### 构建命令

```bash
cd ~/Documents/项目/ClashRemote
swift build
```

release 构建和打包：
```bash
./build.sh
./package-dmg.sh
```
