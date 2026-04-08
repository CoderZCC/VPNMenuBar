# macOS VPN 状态栏 App · 设计文档

- 日期：2026-04-06
- 作者：brainstorming session（用户 + Claude Code）
- 基础：复刻并替代现有 `vpn.py` 的使用场景

## 1. 背景与目标

现状：仓库里有一个 `vpn.py`，通过 `sudo -n openconnect --passwd-on-stdin` 连接 `vpn.example.com`，用 `pyotp` 生成 TOTP，密码是硬编码前缀 + TOTP。所有敏感字段都写死在源码里，连接状态靠 `osascript` 通知提示，只有"启动"没有"断开"能力。

本次要做的是一个 **macOS 状态栏 App**，在 UI 层面替代 `vpn.py`：

- 状态栏常驻图标，展示三种状态：已连接 / 连接中 / 已断开
- 首次启动强制收集用户名、密码前缀、TOTP 密钥三个必填项
- 提供设置入口修改所有配置（必填 + 高级）
- 启动时检查系统依赖（openconnect、sudoers 规则、vpnc-script），缺失时给出可操作的修复指引
- UI 保持干净美观，但不做过度定制

所有面向用户的文案 **统一使用英文**；不引入 i18n 框架，直接写英文字面量即可。

## 2. 关键决策（来自 brainstorming）

| 维度 | 决策 | 理由 |
|---|---|---|
| 目标平台 | **仅 macOS 13+** | `vpn.py` 本身是 macOS 专属（osascript/homebrew/sudo）；且需要 SwiftUI `MenuBarExtra` 的新 API |
| 技术栈 | **Swift + SwiftUI**，`Process` 子进程调 openconnect | 原生 UI 最漂亮；VPN 连接本质就是启动 openconnect 进程，逻辑与 `vpn.py` 1:1 对齐 |
| 密码 / TOTP 密钥存储 | **`~/Library/Application Support/<bundle-id>/config.json` 明文 + 0600 权限** | 用户明确选择；作为个人开发工具在自有机器上是可接受的权衡 |
| 设置面板暴露范围 | **分层：必填 3 项 + 可折叠的高级 5 项** | 常态体验干净；brew 升级等异常情况下不需要改源码 |
| 启动行为 | **登录时自启，但不自动连接** | 通过 `SMAppService.mainApp` 注册；用户自己点菜单里的 Connect |
| 状态栏下拉 | **经典菜单风格**（`MenuBarExtra(.menu)` / NSMenu） | 实现最简，符合系统习惯 |
| 状态栏图标 | **SF Symbol + 右侧彩色小圆点**（绿 / 黄呼吸 / 灰） | 状态醒目，参考 Tailscale 做法 |
| App Sandbox | **关闭** | 要启动 sudo 子进程，Sandbox 会拦截 |
| 签名 / 分发 | **Ad-hoc 签名，不公证，不上架** | 个人工具，用户首次打开时在"系统设置 → 隐私与安全性"放行一次即可 |
| 本地化 | **不做 i18n，所有文案硬编码英文** | 用户指定 |

### 2.1 明确不做的事（YAGNI）

- 不做 NetworkExtension / Packet Tunnel Provider（需 Apple 开发者账号，要重实现 AnyConnect 协议）
- 不做 Keychain（用户选了明文 JSON）
- 不做自动重连（断开后等用户手动处理）
- 不做流量 / IP 显示
- 不做多 profile 切换
- 不做日志面板（stderr 只留最后 200 字节塞进 failed reason）
- 不做 UI 自动化测试（XCUITest / ViewInspector 成本过高）
- 不做 `.strings` / `.xcstrings` 本地化机制

## 3. 架构与模块切分

单 target Xcode 项目，`LSUIElement=true`（无 Dock 图标），最低 macOS 13：

```
VPNMenuBar/
├── App/
│   └── VPNMenuBarApp.swift        // @main, MenuBarExtra scene, Settings scene
├── Core/
│   ├── VPNController.swift        // 状态机 + 对外 API: connect/disconnect/reconnect
│   ├── VPNState.swift             // enum 4 态
│   ├── OpenConnectProcess.swift   // Process 包装：启动 sudo openconnect，写 stdin，读 stderr
│   └── TOTPGenerator.swift        // HMAC-SHA1 TOTP 实现
├── Config/
│   ├── ConfigStore.swift          // 读写 config.json，原子写 + 0600
│   └── VPNConfig.swift            // Codable 结构
├── Dependencies/
│   └── DependencyChecker.swift    // 检查 openconnect / sudoers / vpnc-script
├── UI/
│   ├── StatusBarIconView.swift    // 3 状态的 NSImage 生成
│   ├── MenuContentView.swift      // MenuBarExtra 菜单项构建
│   ├── SettingsView.swift         // SwiftUI Form
│   ├── OnboardingView.swift       // 首次启动向导
│   └── DependencyAlertView.swift  // 依赖缺失窗口
└── Util/
    └── LoginItemManager.swift     // SMAppService 注册/取消
```

### 3.1 模块依赖方向

```
UI ─┐
    ├─► Core ─► Config
    │         └─► Dependencies
    └─► Util
```

单向依赖，无循环。`VPNController` 是 UI 层唯一能触到的 Core 入口，UI 通过 `@StateObject`/`@ObservedObject` 订阅其 `@Published var state: VPNState`；UI 不直接 touch `Process` / `ConfigStore`。

### 3.2 关键协议抽象

为了让 `VPNController` 可单测：

```swift
protocol OpenConnectProcessRunning {
    func start(config: VPNConfig, password: String) throws -> OpenConnectHandle
    func isRunning() -> Bool
    func stop() throws
}
```

生产实现：`OpenConnectProcess`；测试替身：`FakeOpenConnectProcess`（根据脚本驱动状态）。

## 4. 状态机与连接流程

### 4.1 状态定义

```swift
enum VPNState: Equatable {
    case disconnected              // 初始态 / 正常断开后
    case connecting                // 点了 Connect，等 openconnect 握手
    case connected(since: Date)    // 握手成功后
    case failed(reason: String)    // 启动超时、认证失败、sudo 失败等
}
```

### 4.2 connect() 时序

1. **前置校验**
   - `ConfigStore.load()` 读配置；若缺必填字段 → 弹 `OnboardingView`，中止
   - `DependencyChecker.check()` 同步跑一遍；任一失败 → 弹 `DependencyAlertView`，中止
2. `state = .connecting`
3. `TOTPGenerator.now(secret: config.totpSecret)` 生成 6 位码
4. `OpenConnectProcess.start(config:, password: prefix + totp)`
   - 等价命令行：`sudo -n <openconnectPath> --script <vpncScriptPath> --user <username> --passwd-on-stdin --servercert <pin> <gateway>`
   - stdin 写入 `"password\n"`
   - stderr 管入 `Pipe` 用于握手关键字匹配和失败原因截取；stdout 直接丢弃（`FileHandle.nullDevice`）
5. 启动 5 秒超时 Task：
   - 每 250ms `pgrep -x openconnect`
   - 同时异步读 stderr，匹配以下任一关键字即视为握手成功：
     - `Connected as`
     - `CSTP connected`
     - `Established DTLS`
     - `ESP session established`
   - **双重条件**：`pgrep 命中 AND (stderr 关键字命中 OR 已过 1.5s 宽限期)`
   - 超时未命中 → `state = .failed(reason: <stderr 末尾 200 字节>)`
6. 进入 `.connected(since: now)` 后，启动长驻任务：每 2s `pgrep` 一次；进程消失 → `state = .disconnected` + 发通知 `"VPN disconnected unexpectedly"`

### 4.3 disconnect() 实现

`sudo -n /usr/bin/pkill -x openconnect`

需要 visudo 同时把 `pkill -x openconnect` 加到 NOPASSWD 规则里（Dependency 检查的 fixHint 里会连带指引）。

### 4.4 reconnect() 实现

`disconnect()` → 等 `state == .disconnected` → `connect()`

### 4.5 认证失败的判定

stderr 出现 `Login failed` / `authentication failure` → `state = .failed(reason: "Authentication failed — please check your TOTP secret or password prefix.")`

## 5. 配置文件与首次启动

### 5.1 VPNConfig 结构

```swift
struct VPNConfig: Codable {
    // --- Required (collected by Onboarding) ---
    var username: String            // e.g. "first.last"
    var passwordPrefix: String      // e.g. "ExamplePass2021"
    var totpSecret: String          // Base32, e.g. "EXAMPLEBASE32SECRETPLACEHOLDER34"

    // --- Advanced (defaulted from vpn.py; editable in Settings > Advanced) ---
    var gateway: String = "vpn.example.com"
    var serverCertPin: String = "pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    var openconnectPath: String = "/opt/homebrew/bin/openconnect"
    var vpncScriptPath: String = "/opt/homebrew/Cellar/openconnect/9.12_1/.bottle/etc/vpnc/vpnc-script"
    var skipDNSModification: Bool = false   // true → 改用 bundle 内的 vpnc-script--no-dns

    // --- Meta ---
    var schemaVersion: Int = 1
}
```

### 5.2 ConfigStore

- 存储路径：`~/Library/Application Support/com.example.vpnmenubar/config.json`
- 目录不存在时自动创建
- API：
  - `load() throws -> VPNConfig?`（文件不存在返回 nil；JSON 损坏备份为 `config.json.broken-<epoch>` 并返回 nil）
  - `save(_:) throws`（原子写：先写 `.tmp` 再 rename；写完设置权限 0600）
  - `isConfigured: Bool`（三个必填字段都非空即 true）

### 5.3 首次启动流程

```
App launch (login item or manual)
  │
  ▼
ConfigStore.load()
  │
  ├─ nil 或 !isConfigured
  │   │
  │   ▼
  │   OnboardingView (独立窗口, 480×520, 居中)
  │   ├─ Step 1: Welcome + 说明需要的依赖
  │   ├─ Step 2: Dependency check 结果（有缺失就禁用"Next"）
  │   ├─ Step 3: 3 required fields 表单
  │   └─ Step 4: Done, 关窗, 回到状态栏
  │
  └─ 已配置
      └─ 状态栏直接进入 .disconnected，等用户点 Connect
```

Onboarding Step 1 底部附一行小字：
> `Your config is stored locally at ~/Library/Application Support/com.example.vpnmenubar/config.json with 0600 permissions. Nothing is uploaded.`

如果用户关掉 Onboarding 窗口：App 继续运行，状态栏进入 `.failed(reason: "Setup incomplete")`，菜单里只剩 `Open Settings…` 和 `Quit`。

### 5.4 Settings 面板布局

```
┌─────────────────────────────────────────┐
│ Required                                 │
│   Username        [first.last    ] │
│   Password prefix [••••••••••         ] │
│   TOTP secret     [••••••••••••       ] │
│                                          │
│ ▸ Advanced                               │   ← DisclosureGroup, 默认收起
│   Gateway           [vpn.example.com]│
│   Server cert pin   [pin-sha256:...    ]│
│   openconnect path  [/opt/homebrew/...  ]│
│   vpnc-script path  [/opt/homebrew/...  ]│
│   ☐ Skip DNS modification                │
│                                          │
│ ───────────────────────────────────── │
│ ☑ Launch at login                        │   ← LoginItemManager
│                                          │
│ [ Check dependencies… ]        [ Save ] │
└─────────────────────────────────────────┘
```

`Launch at login` 只控制"登录时是否自动让 App 进驻状态栏"，**不会自动触发 VPN 连接**；连接始终由用户在菜单里手动点 Connect。

保存后通过 `NotificationCenter` 通知 `VPNController` 热重载。若当前 `state == .connected`，提示 `"Configuration saved. The new values will take effect on the next connection."`，不强制断开重连。

## 6. 依赖检查

### 6.1 DependencyStatus

```swift
enum DependencyID { case openconnect, sudoersRule, vpncScript }

struct DependencyStatus {
    let id: DependencyID
    let passed: Bool
    let detail: String         // one-line summary
    let fixHint: String        // multi-line instructions, may embed commands
    let fixCommand: String?    // single-line copyable command (for "Copy" button)
}
```

### 6.2 三项检查

| 检查 | 通过条件 | fixHint（英文） |
|---|---|---|
| **openconnect installed** | `FileManager` 找到 `config.openconnectPath` 且 `Process` 跑 `--version` 退出码 0 | `"openconnect not found. Run 'brew install openconnect' in Terminal, then verify the path in Settings → Advanced (default on Apple Silicon: /opt/homebrew/bin/openconnect)."` |
| **sudoers NOPASSWD rule** | `Process` 跑 `sudo -n <openconnectPath> --version`，退出码 0 | `"This app needs to run sudo openconnect without a password prompt. Run 'sudo visudo' and append this line (replacing <user> with your macOS username): <user> ALL=(root) NOPASSWD: <openconnectPath>, /usr/bin/pkill -x openconnect"` （`<user>` / `<openconnectPath>` 动态填入） |
| **vpnc-script exists** | `FileManager` 找到 `config.vpncScriptPath`；若 `skipDNSModification == true` 额外校验 bundle 内打包的 `vpnc-script--no-dns` | `"vpnc-script not found. Brew upgrades change this path. Open Settings → Advanced and update 'vpnc-script path' to /opt/homebrew/Cellar/openconnect/<version>/.bottle/etc/vpnc/vpnc-script"` |

### 6.3 触发时机

1. **Onboarding Step 2**：首次启动全量跑一遍，缺失时"Next"禁用
2. **运行期 connect() 前**：同步跑一遍，任一失败弹 `DependencyAlertView`，`state` 不进入 `.connecting`
3. **手动触发**：菜单常驻 `Check dependencies…`，brew 升级后用户可主动排查

### 6.4 DependencyAlertView

独立 Window，480 宽，高度自适应：

```
┌──────────────────────────────────────────┐
│  ⚠  Dependencies not ready               │
│                                           │
│  ✓ openconnect installed (9.12_1)         │
│  ✗ sudoers NOPASSWD rule missing          │
│  ✓ vpnc-script found                      │
│                                           │
│  ─────────────────────────────────────   │
│  How to fix:                              │
│  Run 'sudo visudo' and append:            │
│                                           │
│  ┌────────────────────────────────────┐  │
│  │ ccz ALL=(root) NOPASSWD: /opt/...  │  │
│  └────────────────────────────────────┘  │
│                              [ Copy ]    │
│                                           │
│                    [ Recheck ]  [ Close ]│
└──────────────────────────────────────────┘
```

"Copy" → `fixCommand` 写入 `NSPasteboard`；"Recheck" 原地刷新。

## 7. 错误处理

| 场景 | 处理 |
|---|---|
| `config.json` JSON 损坏 | 备份为 `config.json.broken-<epoch>`，视作未配置，弹 Onboarding |
| `sudo -n` 非零退出 | 判定 sudoers 问题 → 弹 DependencyAlertView |
| stderr `Login failed` / `authentication failure` | `state = .failed(reason: "Authentication failed — please check your TOTP secret or password prefix.")` |
| 5 秒握手超时 | `state = .failed(reason: <stderr tail 200 bytes>)` + 系统通知 |
| 运行期 openconnect 进程消失 | `state = .disconnected` + 通知 `"VPN disconnected unexpectedly"`，不自动重连 |
| Onboarding 被关闭 | `state = .failed(reason: "Setup incomplete")`；菜单只剩 `Open Settings…` / `Quit` |

所有给用户看的错误都是 **英文一句话 + 可操作建议**；不吐 Swift `Error.localizedDescription`。

## 8. 测试策略

| 层 | 方式 |
|---|---|
| `TOTPGenerator` | XCTest，用 RFC 6238 官方测试向量（secret `GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ`，ts=59 → `287082` 等） |
| `ConfigStore` | XCTest：write→read round-trip；损坏 JSON → 备份逻辑；0600 权限用 `stat` 验证 |
| `DependencyChecker` | 注入 `ProcessRunning` 协议；单测跑三种组合（全过 / sudoers 缺 / openconnect 缺） |
| `VPNController` | 注入 `OpenConnectProcessRunning` 协议；测 connect→failed（认证错）、connect→connected→意外退出→disconnected、disconnect 路径 |
| `OpenConnectProcess` 真实路径 | **手动冒烟**：本机点 Connect 一次，观察状态栏圆点 → 绿，点 Disconnect 一次，观察变灰。不进 CI |
| UI | **不做自动化**。Onboarding / Settings / DependencyAlert 手动点一遍 |

## 9. 打包与分发

- **Xcode**：macOS App target，Swift + SwiftUI，最低系统 macOS 13
- **签名**：Ad-hoc (`-` identity)，未公证
- **App Sandbox**：关闭（要跑 sudo 子进程）
- **安装**：拖到 `/Applications`
- **Bundle ID**：`com.example.vpnmenubar`
- **Info.plist**：
  - `LSUIElement = true`（无 Dock 图标）
  - `NSUserNotificationAlertStyle = alert`
- **登录自启**：`SMAppService.mainApp.register()`
- **Bundle resources**：`vpnc-script--no-dns`（对应 Advanced 里的 Skip DNS modification，免得用户额外管外部文件）
- **首次打开**：macOS 会弹"无法打开"对话框，用户去"System Settings → Privacy & Security → Open Anyway"放行一次。这点写入 README 和 Onboarding 最后一步

## 10. 开放问题

无。所有关键决策均已在 brainstorming 中落定。

## 附录 A · 从 `vpn.py` 迁移过来的默认值

以下值从 `vpn.py` 硬编码中迁出，作为 `VPNConfig` 的默认值（高级字段里可改）：

- `gateway = "vpn.example.com"`
- `serverCertPin = "pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="`
- `openconnectPath = "/opt/homebrew/bin/openconnect"`
- `vpncScriptPath = "/opt/homebrew/Cellar/openconnect/9.12_1/.bottle/etc/vpnc/vpnc-script"`

这三项用户必填（首次启动向导收集）：

- `username`（`vpn.py` 写死为 `first.last`）
- `passwordPrefix`（`vpn.py` 写死为 `ExamplePass2021`）
- `totpSecret`（`vpn.py` 写死为 `EXAMPLEBASE32SECRETPLACEHOLDER34`，已脱敏占位符）
