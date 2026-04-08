# Password Reveal & Username Auto-fill · 设计文档

- 日期：2026-04-07
- 作者：brainstorming session（用户 + Claude Code）
- 基础：在 `2026-04-06-totp-qr-image-import-design.md` 完成的基础上追加两个 UX 改进

## 1. 背景与目标

现状：
- `Password prefix` 与 `TOTP secret` 都是 `SecureField`，用户输入后无法肉眼校对，粘贴错了发现不了
- QR 二维码导入只填 `totpSecret`，`username` 仍需用户手输；运维下发的 otpauth URI 中本来就携带账户信息，应该一并提取

目标：
1. 给 `Password prefix` 和 `TOTP secret` 两个字段都加一个"眼睛"按钮，点一下切换显示/隐藏
2. QR 导入时顺带从 otpauth URI 的 label 段解析出 `username`，**仅在用户当前 username 为空时**才写入

**明确范围**：

- 不做"显示 N 秒后自动隐藏"
- 不解析 `issuer` 字段（用户没要）
- 不支持粘贴 otpauth URL（只走选择图片这一条路）
- 不修改 `VPNConfig` schema —— `username` 字段已存在
- 不引入测试（项目无测试目标）

## 2. 架构

### 2.1 新增文件

```
VPNMenuBar/UI/RevealableSecureField.swift   # 通用：带眼睛切换的 SecureField/TextField
```

### 2.2 修改文件

```
VPNMenuBar/Core/QRCodeSecretExtractor.swift     # 返回结构体而非 String，新增 account 解析
VPNMenuBar/UI/ImportSecretFromImageButton.swift # 新增 username Binding 参数
VPNMenuBar/UI/OnboardingView.swift              # credentialsStep 替换两个 SecureField + 传 username binding
VPNMenuBar/UI/SettingsView.swift                # Required section 同样替换
```

`project.yml` 不需修改，新 `.swift` 文件由递归 sources glob 自动捕获，无需 `xcodegen generate`。

### 2.3 依赖方向

```
RevealableSecureField  ─→  (无依赖, 纯 SwiftUI)

OnboardingView ─┐
                ├─→ RevealableSecureField
                └─→ ImportSecretFromImageButton ─→ QRCodeSecretExtractor
SettingsView   ─┘
```

仍然遵守 CLAUDE.md 的 "UI → Core" 单向约束。

## 3. `RevealableSecureField` 细节

### 3.1 接口

```swift
struct RevealableSecureField: View {
    let title: String
    @Binding var text: String

    @State private var isVisible: Bool = false

    var body: some View { /* HStack { SecureField/TextField + eye Button } */ }
}
```

### 3.2 行为

- 默认 `isVisible == false`，渲染 `SecureField(title, text: $text)`
- 点击眼睛按钮 → `isVisible.toggle()`
- `isVisible == true` 时渲染 `TextField(title, text: $text)` —— 内容明文显示
- 眼睛 icon：`Image(systemName: isVisible ? "eye.slash" : "eye")`
- 按钮样式 `.buttonStyle(.borderless)` + `.help(isVisible ? "Hide" : "Show")`（macOS tooltip）
- 父视图通过 `$text` 取得最新值；切换可见性不影响绑定的字符串

### 3.3 在 Form 内的行为

`SettingsView` 使用 `Form`，每行是 `View`。`HStack { TextField/SecureField; Button }` 会被 Form 当成单行 row 渲染，按钮 `.borderless` 不会撑开行高，与原 `SecureField` 视觉尺寸一致。

`OnboardingView.credentialsStep` 用的是 `VStack`，行为相同。

## 4. `QRCodeSecretExtractor` 接口扩展

### 4.1 新返回结构体

```swift
struct OTPAuthInfo: Equatable {
    let secret: String       // raw Base32, validated by TOTPGenerator.base32Decode
    let account: String?     // parsed username, nil if not extractable
}
```

### 4.2 新接口签名

```swift
enum QRCodeSecretExtractor {
    static func extract(fromImageAt url: URL) throws -> OTPAuthInfo
}
```

旧的 `extractSecret(fromImageAt:) -> String` **直接删除**（无外部复用，仅 `ImportSecretFromImageButton` 在调用，会一起改）。

`QRExtractError` 五个 case **保持不变**。

### 4.3 `account` 解析规则

按顺序应用，任一步出空就返回 `nil`：

1. 从已经解析好的 `URLComponents` 取 `path`，丢掉前导 `/`
2. 调用 `removingPercentEncoding`
3. 如果包含 `:`，取**首个** `:` 之后的子串（剥离 issuer 前缀；例 `Example VPN:john.doe` → `john.doe`）
4. 如果包含 `@`，取**首个** `@` 之前的子串（剥离邮箱域名；例 `first.last@example.com` → `first.last`）
5. `trimmingCharacters(in: .whitespaces)`
6. 若结果为空字符串 → 返回 `nil`，否则返回该字符串

**注意**：解析失败 (`account == nil`) 不会抛错。`secret` 提取与验证流程不变，错误 case 仍是 §3 列出的五种之一。

## 5. `ImportSecretFromImageButton` 接口扩展

### 5.1 新签名

```swift
struct ImportSecretFromImageButton: View {
    @Binding var secret: String
    @Binding var username: String   // NEW
    // ...
}
```

### 5.2 成功路径写入逻辑

```swift
let info = try QRCodeSecretExtractor.extract(fromImageAt: url)
await MainActor.run {
    self.secret = info.secret
    if self.username.isEmpty, let account = info.account {
        self.username = account
    }
    self.isImporting = false
}
```

**关键**：仅在 `self.username.isEmpty` 时才覆盖。已有内容（用户手输或之前导入过）保持不动。

错误路径与 `isImporting` 重置逻辑维持原样。

## 6. 调用站点改动

### 6.1 `OnboardingView.credentialsStep`

```swift
private var credentialsStep: some View {
    VStack(alignment: .leading, spacing: 12) {
        Text("Credentials").font(.title2).bold()
        TextField("Username", text: $config.username)
        RevealableSecureField(title: "Password prefix", text: $config.passwordPrefix)
        RevealableSecureField(title: "TOTP secret (Base32)", text: $config.totpSecret)
        HStack {
            ImportSecretFromImageButton(secret: $config.totpSecret, username: $config.username)
            Spacer()
        }
        Text("These three fields are required. Defaults for gateway, cert pin, and paths are already filled in and can be edited later in Settings → Advanced.")
            .font(.caption).foregroundColor(.secondary)
    }
}
```

### 6.2 `SettingsView` Required section

```swift
Section("Required") {
    TextField("Username", text: $config.username)
    RevealableSecureField(title: "Password prefix", text: $config.passwordPrefix)
    RevealableSecureField(title: "TOTP secret (Base32)", text: $config.totpSecret)
    HStack {
        ImportSecretFromImageButton(secret: $config.totpSecret, username: $config.username)
        Spacer()
    }
}
```

## 7. 错误处理

无新增错误路径。`account` 解析失败是预期场景（不是错误），表现为 `account == nil` → 用户手填即可。

## 8. 测试策略

项目无测试目标。手动冒烟：

1. 导入一张 `otpauth://totp/Example:first.last?secret=...` 二维码 → username 字段为空时自动填 `first.last`，secret 同时填入
2. 同上场景，但 username 已有内容 → username 保持不变，secret 仍被覆盖
3. 导入 `otpauth://totp/first.last@example.com?secret=...` → 自动填 `first.last`（剥离 `@example.com`）
4. 点 Password prefix 旁的眼睛 → 字段变为明文，再点一次变回掩码
5. 同上对 TOTP secret 字段
6. Settings 里改完密码点 Save → 即便眼睛是开着的，保存逻辑不受影响
7. 端到端：导入 + 显示验证 + Connect VPN → 连接成功

## 9. 不改动的部分

- `VPNConfig` schema 不变
- `ConfigStore`、`TOTPGenerator`、`OpenConnectProcess`、`VPNController` 不涉及
- `QRExtractError` 不变
- `INSTALL.md`、`install-deps.sh`、`project.yml` 不变
