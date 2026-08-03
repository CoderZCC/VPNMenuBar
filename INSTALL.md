# VPN MenuBar · 安装与使用说明

macOS 状态栏小工具，封装 `openconnect` 连接 Cisco AnyConnect 兼容的 VPN，自动生成 TOTP 一次性口令。

> ⚠️ **这是一个通用 VPN 前端**。仓库里默认的 `vpn.example.com`、cert pin、密码前缀都是**占位符**，需要你在 Onboarding 向导（或 Settings → Advanced）里换成你**自己 VPN** 的值（一般由你的 VPN 管理员提供）。

## 系统要求

- **macOS 13** 或更高版本
- **Intel Mac 或 Apple Silicon** 均可（Universal Binary）
- 需要 **Homebrew**（没装的话 app 内 Onboarding 也能引导你装）

## 快速安装（推荐）

**从 app 内一键安装依赖**，全程不用开终端：

1. 仓库 clone 下来后，把 `VPNMenuBar.app` 拷到 `/Applications`：
   ```sh
   git clone https://github.com/CoderZCC/VPNMenuBar.git
   cp -R VPNMenuBar/VPNMenuBar.app /Applications/
   xattr -dr com.apple.quarantine /Applications/VPNMenuBar.app   # 解除 Gatekeeper 隔离
   open /Applications/VPNMenuBar.app
   ```
2. **首次启动**：如果上面没跑 `xattr`，需要右键点 .app → 选"打开" → 警告框里再次点"打开"（参见"手动安装步骤"第 2 步）
3. 状态栏出现盾牌图标后会自动弹出 Onboarding 向导。**Step 2 (Dependency Check)** 会列出依赖项，每个红叉旁边都有一个 **Fix 按钮**：
   - **Homebrew** 缺失 → 点 **Open Terminal**：自动跳到终端并预填 brew 官方安装命令，按 Enter 输入一次 macOS 密码，等 5–10 分钟，装完关终端
   - **openconnect** 缺失 → 点 **Install via brew**：app 内自动跑 `brew install openconnect`，30–120 秒，全程在窗口里看进度
   - **sudo NOPASSWD rule** 缺失/不完整 → 点 **Configure sudo permissions**：弹 macOS 系统鉴权框（TouchID 或密码），按一下完成
   - **vpnc-script** 路径错（Intel / ARM 不一致）→ 点 **Reset path**：自动改回当前架构的默认路径
4. 全绿之后点 Next 进 Step 3，填**你自己 VPN** 的用户名 / 密码前缀 / TOTP 密钥，再去 Settings → Advanced 把 gateway 和 cert pin 换成你的 VPN 服务器值

**Intel Mac**：新版自动检测架构，依赖检查直接探测 `/usr/local/...` 路径，**不需要手动去 Settings → Advanced 改 openconnect/vpnc-script 路径**（gateway 和 cert pin 仍要自己填）。

> 💡 **兜底**：如果 app 内一键安装走不通（比如 Mac 有 MDM 限制 / osascript 鉴权一直失败），仓库里还带一个 `install-deps.sh`，效果跟 app 里的 Fix 按钮一致。脚本是幂等的，反复运行不会出问题：
> ```sh
> cd VPNMenuBar
> bash install-deps.sh
> ```

## 从 GitHub Releases 下载（最简单）

不需要 git，直接从 Release 页面下载最新版：

1. 打开 [最新 Release](https://github.com/CoderZCC/VPNMenuBar/releases/latest)，下载 `VPNMenuBar-x.y.z.zip`
2. 解压后把 `VPNMenuBar.app` 拖到 `/Applications`
3. 终端执行 `xattr -dr com.apple.quarantine /Applications/VPNMenuBar.app`（或者右键 → 打开 → 打开）
4. 启动后走 Onboarding 向导

之后有新版本时，app 会**自动提示更新**，点"安装更新"即可，不用再手动下载。也可以随时从状态栏菜单点 **Check for Updates…** 手动检查。

---

## 手动安装步骤

如果不想用脚本,按下面的顺序逐步手动来也可以。

### 1. 拷贝到 Applications

仓库里直接带了构建好的 `VPNMenuBar.app`（Universal Binary，ad-hoc 签名）。clone 下来后拷到 **`/Applications`** 即可：

```sh
git clone https://github.com/CoderZCC/VPNMenuBar.git
cp -R VPNMenuBar/VPNMenuBar.app /Applications/
```

或者从源码构建（参见仓库根目录的 `README.md` 里的 Build 步骤）。

### 2. 首次启动（Gatekeeper 拦截）

这个 app 没有 Apple 开发者签名，第一次打开 macOS 会拦截。按下面任一方式放行：

**方法 A（推荐）**
1. 在 `/Applications` 里**右键点击** `VPNMenuBar.app`
2. 选择菜单里的 **"打开"**
3. 弹出的警告框里再点一次 **"打开"**

之后就可以正常双击启动，不会再提示。

**方法 B（如果方法 A 不行 / 提示"已损坏"）**
打开 **终端** 执行：
```sh
xattr -dr com.apple.quarantine /Applications/VPNMenuBar.app
```
再双击打开即可。

### 3. 安装 openconnect

在终端执行：
```sh
brew install openconnect
```

### 4. 配置 sudo 免密（最关键一步）

App 需要免密调用 `sudo openconnect` 来建立 VPN 隧道、`sudo pkill` 来断开，还有 `sudo route` 来清理切 WiFi 后残留的脏路由。**没这一步 app 无法工作**。

在终端执行：
```sh
sudo visudo
```
输入你的 macOS 登录密码，打开编辑器后，按 `G` 跳到文件末尾，按 `o` 进入插入模式，**贴入下面这行**（⚠️ 把 `<你的用户名>` 换成你的 macOS 用户名）：

**Apple Silicon (M 系列) Mac**：
```
<你的用户名> ALL=(root) NOPASSWD: /opt/homebrew/bin/openconnect, /usr/bin/pkill -x openconnect, /sbin/route
```

**Intel Mac**：
```
<你的用户名> ALL=(root) NOPASSWD: /usr/local/bin/openconnect, /usr/bin/pkill -x openconnect, /sbin/route
```

不知道自己用户名的话，执行 `whoami` 查看。

完成后按 `Esc`，输入 `:wq` 回车保存退出。

验证是否生效：
```sh
sudo -n /opt/homebrew/bin/openconnect --version    # Apple Silicon
sudo -n /usr/local/bin/openconnect --version       # Intel
```
如果直接打印出版本号没再要密码，配置成功。

## 首次启动引导（Onboarding）

启动 app 后会看到状态栏出现一个蓝色盾牌图标，同时弹出 Setup 向导窗口：

### Step 1 · Welcome
介绍必备条件，点 **Next** 继续。

### Step 2 · Dependency Check
自动检查三项依赖：
- **openconnect installed** — 是否装了 openconnect
- **sudo NOPASSWD rule** — sudoers 是否配置正确
- **vpnc-script found** — VPN 辅助脚本是否存在

**三项全绿**才能继续。任一项是红叉，点击 **Recheck** 之前先按红叉下面的英文提示修复，右边的 **Copy** 按钮可以直接把修复命令复制到剪贴板。

> 💡 **Intel Mac 用户注意**：三项里 openconnect path 和 vpnc-script path 可能显示红叉，因为默认路径是 Apple Silicon 的 `/opt/homebrew`。你需要点关闭向导窗口（状态会变成 "Setup incomplete"），从状态栏菜单走 Onboarding 或者先完成其它步骤后去 Settings → Advanced 把路径改成：
> - `openconnect path`: `/usr/local/bin/openconnect`
> - `vpnc-script path`: `/usr/local/etc/vpnc/vpnc-script`
>
> 然后回到 Dependency Check 点 Recheck。

### Step 3 · Credentials
填三个必填字段：
- **Username**：VPN 登录用户名（例如 `zhangsan.li`）
- **Password prefix**：固定密码前缀（你的 VPN 管理员告诉你的，多数公司部署里所有人共用同一个前缀）
- **TOTP secret (Base32)**：**你自己的** TOTP 密钥（从 VPN 管理员发给你的 QR 码里提取出来，详见下面 [如何获取 TOTP 密钥](#如何获取-totp-密钥)）。一串大写字母 + 数字 2–7 组成的 Base32 字符串，长度通常 16–32 位，**绝对不要用别人的**

> 💡 此外，**Settings → Advanced** 里还有 `Gateway`（VPN 服务器地址）和 `Server cert pin`（证书 SHA-256 指纹）两个字段，仓库里默认是 `vpn.example.com` 占位符，**你必须换成你自己 VPN 服务器的真实值**才能连上。证书指纹可以用 `openssl s_client -connect <你的vpn>:443 -showcerts </dev/null 2>/dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64` 一行算出来，前面加 `pin-sha256:` 前缀填进去。

填完点 **Save & Continue**。

#### 如何获取 TOTP 密钥

VPN 管理员通过自助门户 / 邮件 / 企业 IM 等渠道给你一张 QR 码图片。**你要的不是用手机扫码注册 Authenticator，而是要把 QR 码里的 Base32 秘钥文本提取出来**（因为 VPNMenuBar 需要的是秘钥本身，不是动态 6 位码）。

> 💡 **更省事的办法**：Onboarding Step 3 和 Settings 里的 TOTP secret 字段旁边有一个 **📷 Import from image** 按钮，直接选 QR 码图片就能自动解码并填入，不用走下面这些命令行步骤。下面三种方法是手动备份方案。

**方法 A · 用 zbar 命令行解码（推荐,本地处理不泄露）**

1. 把 QR 码图片保存到本地,比如 `~/Desktop/vpn-qr.png`
2. 装 `zbar` 解码工具:
   ```sh
   brew install zbar
   ```
3. 解码:
   ```sh
   zbarimg ~/Desktop/vpn-qr.png
   ```
4. 输出一行类似:
   ```
   QR-Code:otpauth://totp/example:your.name@example?secret=ABCDEFGHIJKLMNOP2345&issuer=example
   ```
5. **`secret=` 后面、`&` 前面的那段就是你要的 TOTP 密钥**（例子里是 `ABCDEFGHIJKLMNOP2345`),复制到 Onboarding 的 TOTP secret 字段

**方法 B · 用 iPhone 相机**

iOS 相机自带 QR 码识别,打开相机对准 QR 码,屏幕顶部会弹出一个黄色横幅,点进去会显示完整的 `otpauth://...` URL。从中截取 `secret=` 后面的部分,通过 iMessage / AirDrop 发回 Mac 粘进去即可。

**方法 C · 如果你已经在用 1Password / Bitwarden / Authy 等支持 TOTP 的密码管理器**

这些工具存 TOTP 条目时都会保留 Base32 秘钥,可以直接查看:
- **1Password**:打开对应条目 → "一次性密码" 字段 → 编辑 → "查看二维码" 或显示 `otpauth://` URI,里面能找到 `secret=`
- **Bitwarden**:对应条目的 "Authenticator Key" 字段直接就是 Base32
- **Authy**:部分版本允许在条目详情里查看

> ⚠️ **Google Authenticator / Microsoft Authenticator 看不到秘钥明文** —— Google / Microsoft 出于安全故意禁用了这个功能。如果你的秘钥只存在这两个 app 里没有备份,只能请运维重新签发一张 QR 码,用方法 A 重新抄一遍

> 🔒 **不要用在线 QR 码解码网站** —— 那相当于把你的 VPN 账号凭证上传给一个陌生服务。zbar 完全本地处理,安全得多。

### Step 4 · All Set
点 **Done** 关闭向导，回到状态栏。

## 日常使用

### 连接 / 断开

点击菜单栏的盾牌图标，出现下拉菜单：

| 状态 | 菜单项 |
|---|---|
| 未连接 | `Connect` — 点击开始连接 |
| 连接中 | `Connecting…`（禁用状态）|
| 已连接 | `Disconnect` — 断开；`Reconnect` — 重连 |

盾牌图标右下角的彩色小圆点代表当前状态：
- 🟢 **绿色**：已连接
- 🟠 **橙色**：连接中
- 🔴 **红色**：连接失败
- ⚫ **灰色**：未连接

### 修改配置

菜单里点 **Open Settings…** 打开设置窗口，可以修改所有字段（用户名、密码前缀、TOTP 密钥、网关地址、证书指纹等）。点 **Save** 保存，会弹出 "Settings Saved" 确认对话框。

### 依赖自检

菜单里点 **Check Dependencies…** 随时手动触发依赖检查。`brew upgrade openconnect` 之后如果发现连不上，可以先跑这个排查。

### 退出 app

菜单里点 **Quit**。如果当前正连着 VPN，app 会先断开 VPN 再退出，不会留下僵尸 openconnect 进程。

## 自动化行为

这个 app 内置了几个不需要你手动操作的行为：

- **开机自启**：首次启动会自动注册为登录项（Login Item），下次开机自动启动到状态栏。不想要的话 Settings 里关掉 `Launch at login`。
- **断网自动断开**：连接中如果网络断了（比如切 Wi-Fi、断网），会主动断开 VPN 避免卡死
- **联网自动恢复**：如果之前是你主动连的，网络恢复后会自动重连（之前主动 Disconnect 过就不会）
- **跳过 DNS 修改**：默认开启。这意味着 VPN 不会改你系统的 DNS 设置（对不想让 VPN 干扰本地 DNS 解析的同学更友好）。想让 VPN 接管 DNS 的话 Settings → Advanced 里关掉 `Skip DNS modification`

## 常见问题

### Q1. 状态一直卡在 Connecting / 立刻变成 Failed，怎么办？

1. 菜单里点 **Check Dependencies…**，看三项是不是都绿
2. 如果 sudoers 那项红了：重新检查 visudo 那行是不是正确贴了、用户名对不对、路径对不对（Intel / ARM 不一样）
3. 如果是 TOTP 秘钥错了：Failed 提示会写 `Authentication failed — please check your TOTP secret or password prefix.`，去 Settings 重新填
4. 如果是证书指纹变了（运维换证书后会这样）：Failed 提示会写 `Server certificate verification failed.`，去 Settings → Advanced 更新 `Server cert pin`

### Q1.5. 切了 WiFi 之后连不上 / Failed to connect to host &lt;你的 VPN 域名&gt;？

典型表现：上一个 WiFi 上跑过 VPN，断电/睡眠/直接关 app 没走干净退出，路由表里残留一条指向**原来那个 WiFi 网关**的 host 路由。换到新 WiFi 后那个网关 IP 不存在，于是 openconnect 包发不出去就报这个错。

**app 内置自动处理** —— 每次点 Connect 之前会先扫一遍路由表，发现脏路由自动 `sudo route delete` 掉再连。如果你还见到这个错：

1. 先确认 sudoers 已经包含 `/sbin/route`（文件名里用户名中的 `.` 会被替换成 `_`，所以用通配符最稳妥）：
   ```sh
   sudo cat /etc/sudoers.d/vpnmenubar-*
   ```
   末尾那行应该是 `..., /usr/bin/pkill -x openconnect, /sbin/route`。如果没有 `/sbin/route`，**重跑一次** Onboarding 里 sudoers 那行的 **Configure sudo permissions** 按钮（或者 `bash install-deps.sh`，脚本检测到旧规则会自动覆盖）。
2. 还不行的话，手动删一下脏路由验证一下（把 `&lt;你的VPN域名&gt;` 换成你 Settings 里填的 gateway）：
   ```sh
   route -n get <你的VPN域名>    # 看 gateway 是不是当前默认网关
   sudo route -n delete <你的VPN域名>
   ```

### Q2. brew upgrade openconnect 之后连不上了？

这个 app 用的是稳定路径 `/opt/homebrew/etc/vpnc/vpnc-script`（Homebrew 会自动维护这个符号链接），brew upgrade 不应该影响。如果真的断了，进 Settings → Advanced 确认路径还对。

### Q3. 我想彻底卸载怎么办？

```sh
# 断开并退出 app
# （菜单里点 Disconnect 再 Quit）

# 删除 app
rm -rf /Applications/VPNMenuBar.app

# 删除本地配置（包含 TOTP 密钥）
rm -rf ~/Library/Application\ Support/com.example.vpnmenubar

# 删除偏好设置
rm -f ~/Library/Preferences/com.example.vpnmenubar.plist

# 删除 sudoers 免密规则（可选）
# 规则单独放在一个文件里，直接删文件即可（文件名里用户名的 . 会被写成 _，用通配符匹配）
ls /etc/sudoers.d/vpnmenubar-* && sudo rm /etc/sudoers.d/vpnmenubar-*
```

### Q4. 状态栏图标不见了？

app 进程可能被杀了。打开 `/Applications/VPNMenuBar.app` 重新启动即可。

### Q5. 能不能同时连两个 VPN？

不能。这个 app 只管理一个 openconnect 连接。系统级别上也不推荐同时拉两条 TUN 隧道。

## 配置文件与隐私

- **配置位置**：`~/Library/Application Support/com.example.vpnmenubar/config.json`
- **权限**：`0600`（只有你自己能读写）
- **内容**：明文 JSON，包含用户名、密码前缀、TOTP 密钥、网关地址等
- **不会上传到任何地方** —— 完全本地存储

⚠️ **安全提醒**：
- **TOTP 密钥是你本人账号独有的**，等同于一次性密码的种子。**绝对不要把 config.json 发给别人**，也不要提交到 git 仓库
- 每个同事都应该从运维那里**各自拿自己的 TOTP 密钥**走 Onboarding 流程填进去，而不是拷贝别人的配置

## 反馈

有 bug 或改进建议，欢迎在 GitHub 上提 issue 或 PR：
<https://github.com/CoderZCC/VPNMenuBar/issues>
