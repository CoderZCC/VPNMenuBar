# TOTP 密钥从二维码图片导入 · 设计文档

- 日期：2026-04-06
- 作者：brainstorming session（用户 + Claude Code）
- 基础：在现有 macOS VPN 状态栏 App 上追加一个便利功能

## 1. 背景与目标

现状：用户拿到的 TOTP 密钥来自运维提供的二维码。目前 App 内没有任何图片识别能力，用户必须借助外部工具（`zbar` CLI、iPhone 相机、1Password/Bitwarden 等；见 `INSTALL.md`）先把二维码解出来，再把 Base32 密钥手动粘贴到 Onboarding 第 3 步或 Settings → Required 的 `SecureField`。

目标：在 App 内直接支持"选图→识别→填入"的一步式流程，不再依赖外部工具，降低上手和换发密钥的摩擦。

**明确范围**：

- 仅支持从本地磁盘选图（NSOpenPanel），不做剪贴板粘贴、不做拖拽
- 仅识别标准 `otpauth://totp/...?secret=BASE32` URI（运维下发的就是这种）
- 不解析/展示 `issuer`、`label`，用户只需要 `secret` 字段
- 不做测试（项目无测试目标；见 CLAUDE.md）

## 2. 架构

### 2.1 新增文件

```
VPNMenuBar/Core/QRCodeSecretExtractor.swift    # 纯逻辑
VPNMenuBar/UI/ImportSecretFromImageButton.swift # SwiftUI 组件
```

### 2.2 修改文件

```
VPNMenuBar/UI/OnboardingView.swift   # credentialsStep 里加一行按钮
VPNMenuBar/UI/SettingsView.swift     # Required section 里加一行按钮
```

源码是 `project.yml` 里的递归 glob，新增 Swift 文件**不需要** `xcodegen generate`。

### 2.3 依赖方向

```
ImportSecretFromImageButton  ─┐
                              ├─→  QRCodeSecretExtractor  ─→  TOTPGenerator.base32Decode
OnboardingView ──┐            │
                 ├─→ ImportSecretFromImageButton
SettingsView ────┘
```

符合 CLAUDE.md 中 "UI → Core" 的单向依赖约束。

## 3. `QRCodeSecretExtractor` 细节

### 3.1 接口

```swift
enum QRExtractError: Error, LocalizedError, Equatable {
    case imageLoadFailed
    case noQRCodeFound
    case notOtpauthURI
    case missingSecret
    case invalidBase32

    var errorDescription: String? { /* English literals */ }
}

enum QRCodeSecretExtractor {
    /// Load the image at `url`, find a QR code, parse it as an otpauth://totp URI,
    /// and return the Base32 `secret` query parameter (validated via TOTPGenerator.base32Decode).
    static func extractSecret(fromImageAt url: URL) throws -> String
}
```

`extractSecret` 是同步函数 —— 调用方负责用 `Task.detached` 放到后台线程，避免阻塞主线程。

### 3.2 实现步骤

1. **加载图片**
   - 用 `NSImage(contentsOf: url)` 读取，再取 `cgImage(forProposedRect: nil, context: nil, hints: nil)`。失败 → `imageLoadFailed`。
2. **识别 QR**
   - 用 Vision 框架：`VNImageRequestHandler(cgImage:options:)` + `VNDetectBarcodesRequest`（限制 `symbologies = [.qr]`）
   - `perform([request])` 同步执行
   - `request.results` 为空或没有 payload → `noQRCodeFound`
   - 取第一个结果的 `payloadStringValue`
3. **解析 URI**
   - `URLComponents(string: payload)`
   - `scheme == "otpauth"` 且 `host == "totp"`，否则 → `notOtpauthURI`
   - `queryItems?.first(where: { $0.name == "secret" })?.value` 为空 → `missingSecret`
4. **验证 Base32**
   - `try TOTPGenerator.base32Decode(rawSecret)`，抛错 → `invalidBase32`
   - 成功 → 返回**原始**的 Base32 字符串（保留运维给的大小写/格式，不做规范化）

### 3.3 错误文案（英文字面量）

| Case | errorDescription |
|---|---|
| `imageLoadFailed` | "Could not read the selected file as an image." |
| `noQRCodeFound` | "No QR code was found in this image." |
| `notOtpauthURI` | "The QR code is not a TOTP otpauth URI." |
| `missingSecret` | "The otpauth URI does not contain a secret parameter." |
| `invalidBase32` | "The secret in the QR code is not valid Base32." |

## 4. `ImportSecretFromImageButton` 细节

### 4.1 接口

```swift
struct ImportSecretFromImageButton: View {
    @Binding var secret: String

    @State private var errorMessage: String?
    @State private var showError: Bool = false
    @State private var isImporting: Bool = false

    var body: some View { /* Button + alert */ }
}
```

### 4.2 行为

- 按钮标题：`"Import from QR image…"`
- 点击 → `NSOpenPanel`：
  - `canChooseFiles = true`, `canChooseDirectories = false`, `allowsMultipleSelection = false`
  - `allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic]`（用 `UniformTypeIdentifiers` 的 `UTType`）
- 选中文件后设 `isImporting = true`，`Task.detached` 调 `QRCodeSecretExtractor.extractSecret(fromImageAt:)`
- 回主线程：
  - 成功 → `self.secret = result`（`@Binding` 自动刷新上游 `SecureField`）
  - 失败 → `errorMessage = error.localizedDescription; showError = true`
  - 无论成败 → `isImporting = false`
- `.alert("Import failed", isPresented: $showError) { Button("OK") {} } message: { Text(errorMessage ?? "") }`
- 按钮在 `isImporting == true` 时 disabled，标题加 `ProgressView`（视觉上区分开）

### 4.3 布局

- **OnboardingView.credentialsStep**：在 `SecureField("TOTP secret (Base32)", …)` 下方另起一行放按钮，`HStack { ImportSecretFromImageButton(secret: $config.totpSecret); Spacer() }`
- **SettingsView Required section**：同样在 `SecureField` 下方加一行（`Form` 里用单独的 row）

按钮样式沿用 SwiftUI 默认 `Button`，不做自定义。

## 5. 并发与线程

Vision 的 `VNImageRequestHandler.perform([request])` 是同步调用，根据图片大小可能阻塞几十到几百毫秒。`ImportSecretFromImageButton` 的触发逻辑必须把它放到 `Task.detached(priority: .userInitiated)` 里执行，结果通过 `await MainActor.run` 写回 `@Binding`。

`QRCodeSecretExtractor` 本身是同步纯函数，不持有状态，线程安全。

## 6. 错误处理原则

- 所有异常在 `ImportSecretFromImageButton` 内部 catch，转成用户可见的 `errorMessage`
- 不影响现有 VPN 流程：导入失败时 `totpSecret` 保持原值不变，用户可以重试或手动粘贴
- `NSOpenPanel` 取消（`runModal() != .OK`）是正常路径，不弹错误

## 7. 测试策略

项目无测试目标（见 CLAUDE.md "Tests: none"）。手动冒烟测试：

1. 从运维发来的真实二维码截图导入 → `SecureField` 填充正确的 Base32
2. 导入一张无二维码的普通图片 → 弹出 `noQRCodeFound` alert
3. 导入一张非 otpauth 二维码（例如一个网址 QR）→ 弹出 `notOtpauthURI` alert
4. 取消 NSOpenPanel → 无任何变化、无 alert
5. 导入后立即 Connect VPN → TOTP 生成成功、连接成功

## 8. 不改动的部分

- `VPNConfig` 字段、`ConfigStore` 序列化格式、`TOTPGenerator`、`OpenConnectProcess`、`VPNController` 均不涉及
- `INSTALL.md` 中对外部工具（zbar 等）的说明暂时保留，作为 fallback；可在实现完成后另行决定是否精简
- `project.yml` 不需要修改
