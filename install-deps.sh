#!/usr/bin/env bash
#
# install-deps.sh — One-shot dependency installer for VPNMenuBar.app.
#
# Usage:
#     bash install-deps.sh
#
# What this script does:
#     1. Checks that macOS >= 13
#     2. Detects Intel vs Apple Silicon and picks the correct Homebrew prefix
#     3. Installs Homebrew if missing (NONINTERACTIVE=1 mode;
#        will download Xcode Command Line Tools and prompt for sudo password)
#     4. Installs openconnect via Homebrew (idempotent)
#     5. Writes a sudoers NOPASSWD rule to /etc/sudoers.d/vpnmenubar-<user>
#        (prompts for login password once if not already cached)
#        Grants passwordless sudo for: openconnect, pkill -x openconnect,
#        and /sbin/route (used to scrub stale host routes after WiFi switch)
#     6. Verifies sudo -n openconnect works
#
# Safe to re-run: every step is idempotent.
#
# To uninstall the sudoers rule later:
#     sudo rm /etc/sudoers.d/vpnmenubar-$(whoami)

set -e

# ---------- pretty output helpers ----------
R=$'\033[0;31m'
G=$'\033[0;32m'
Y=$'\033[0;33m'
B=$'\033[0;34m'
N=$'\033[0m'

ok()   { printf "${G}✓${N} %s\n" "$*"; }
fail() { printf "${R}✗${N} %s\n" "$*" >&2; }
warn() { printf "${Y}!${N} %s\n" "$*"; }
info() { printf "  %s\n" "$*"; }
step() { printf "\n${B}==${N} ${B}%s${N}\n" "$*"; }

# ---------- 1. macOS version ----------
step "Step 1/5 · 检查 macOS 版本"
OS_VERSION=$(sw_vers -productVersion)
OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
if [ "$OS_MAJOR" -lt 13 ]; then
    fail "当前 macOS 版本 $OS_VERSION 过低,VPNMenuBar 要求 macOS 13 或更高"
    exit 1
fi
ok "macOS $OS_VERSION"

# ---------- 2. architecture detection ----------
step "Step 2/5 · 检测系统架构"
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    BREW_PREFIX="/opt/homebrew"
    info "Apple Silicon (arm64) — 将使用 $BREW_PREFIX"
else
    BREW_PREFIX="/usr/local"
    info "Intel Mac ($ARCH) — 将使用 $BREW_PREFIX"
fi
OPENCONNECT="$BREW_PREFIX/bin/openconnect"
VPNC_SCRIPT="$BREW_PREFIX/etc/vpnc/vpnc-script"

# ---------- 3. Homebrew ----------
step "Step 3/5 · 检查 Homebrew"

# Resolve brew: either on PATH, or at the architecture's canonical location
# (installed but current shell hasn't sourced the shellenv).
if command -v brew >/dev/null 2>&1; then
    BREW_BIN="$(command -v brew)"
    ok "Homebrew 已安装: $(brew --version | head -1)"
elif [ -x "$BREW_PREFIX/bin/brew" ]; then
    BREW_BIN="$BREW_PREFIX/bin/brew"
    eval "$("$BREW_BIN" shellenv)"
    ok "检测到 Homebrew 在 $BREW_PREFIX (已临时加入本脚本的 PATH)"
else
    warn "未安装 Homebrew — 即将自动安装"
    info "这会下载 Xcode Command Line Tools (如果还没装) + Homebrew 本体"
    info "首次安装通常需要 3–10 分钟,取决于网络速度"
    info "安装过程中可能要求输入 macOS 登录密码 (sudo)"
    info ""

    if ! NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        fail "Homebrew 安装失败"
        info "请手动执行下面这行后重新运行本脚本:"
        printf '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n'
        exit 1
    fi

    if [ ! -x "$BREW_PREFIX/bin/brew" ]; then
        fail "Homebrew 安装脚本退出成功,但 $BREW_PREFIX/bin/brew 不存在"
        exit 1
    fi

    BREW_BIN="$BREW_PREFIX/bin/brew"
    eval "$("$BREW_BIN" shellenv)"
    ok "Homebrew 安装完成: $("$BREW_BIN" --version | head -1)"

    if [ "$ARCH" = "arm64" ]; then
        info ""
        info "⚠️  注意: Apple Silicon 上 Homebrew 不会自动加入新 shell 的 PATH"
        info "如果你想在其它终端窗口直接用 brew 命令,执行一次:"
        info "    echo 'eval \"\$($BREW_PREFIX/bin/brew shellenv)\"' >> ~/.zprofile"
        info "    source ~/.zprofile"
        info "(本脚本后续步骤不受影响,已经临时设置好 PATH)"
    fi
fi

# ---------- 4. openconnect ----------
step "Step 4/5 · 安装 openconnect"
if [ -x "$OPENCONNECT" ]; then
    OC_VERSION=$("$OPENCONNECT" --version 2>&1 | head -1)
    ok "openconnect 已安装: $OC_VERSION"
else
    info "正在通过 Homebrew 安装 openconnect (首次安装可能需要几分钟)..."
    brew install openconnect
    if [ ! -x "$OPENCONNECT" ]; then
        fail "安装后仍未在 $OPENCONNECT 找到 openconnect,请手动排查"
        exit 1
    fi
    ok "openconnect 安装完成"
fi

if [ -f "$VPNC_SCRIPT" ]; then
    ok "vpnc-script 已就绪: $VPNC_SCRIPT"
else
    warn "未找到 $VPNC_SCRIPT"
    info "VPN 连接时会需要它。请检查 Homebrew 是否完整安装了 openconnect,或者"
    info "去 VPNMenuBar 的 Settings → Advanced 里手动指定 vpnc-script 路径。"
fi

# ---------- 5. sudoers NOPASSWD rule ----------
step "Step 5/5 · 配置 sudoers 免密规则"
USER_NAME=$(whoami)
SUDOERS_FILE="/etc/sudoers.d/vpnmenubar-$USER_NAME"
SUDOERS_LINE="$USER_NAME ALL=(root) NOPASSWD: $OPENCONNECT, /usr/bin/pkill -x openconnect, /sbin/route"

# Idempotency check: does sudo -n already work for BOTH openconnect AND
# /sbin/route? The route entry was added later — old sudoers files only
# have the openconnect/pkill rules and need to be rewritten.
if sudo -n "$OPENCONNECT" --version >/dev/null 2>&1 \
   && sudo -n /sbin/route -n get default >/dev/null 2>&1; then
    ok "sudoers NOPASSWD 规则已生效,无需修改"
else
    info "将创建 $SUDOERS_FILE,内容如下:"
    printf "  %s\n" "$SUDOERS_LINE"
    info ""
    info "这一步会要求你输入 macOS 登录密码 (仅此一次,后续使用无感)"
    info ""

    TMPFILE=$(mktemp -t vpnmenubar-sudoers)
    trap 'rm -f "$TMPFILE"' EXIT
    {
        echo "# Auto-generated by VPNMenuBar install-deps.sh at $(date)"
        echo "# Grants $USER_NAME passwordless sudo for openconnect, pkill,"
        echo "# and /sbin/route (used to clear stale host routes after WiFi switch)."
        echo "# Remove this file to revoke: sudo rm $SUDOERS_FILE"
        echo "$SUDOERS_LINE"
    } > "$TMPFILE"

    # Syntax-validate before touching /etc/sudoers.d/
    if ! visudo -c -f "$TMPFILE" >/dev/null 2>&1; then
        fail "生成的 sudoers 文件语法检查失败,以下是内容:"
        cat "$TMPFILE"
        exit 1
    fi

    # Install with 0440 perms owned by root (required by sudo)
    if ! sudo install -m 440 -o root -g wheel "$TMPFILE" "$SUDOERS_FILE"; then
        fail "无法写入 $SUDOERS_FILE (可能是 sudo 密码输入错误或取消)"
        exit 1
    fi

    ok "已写入 $SUDOERS_FILE"

    # Verify it actually took effect (both openconnect and route entries)
    if sudo -n "$OPENCONNECT" --version >/dev/null 2>&1 \
       && sudo -n /sbin/route -n get default >/dev/null 2>&1; then
        ok "验证通过: sudo -n openconnect 和 sudo -n route 都可免密运行"
    else
        fail "写入成功但 sudo -n 仍然失败,请手动检查:"
        info "  sudo cat $SUDOERS_FILE"
        info "  sudo visudo -c"
        exit 1
    fi
fi

# ---------- done ----------
printf "\n${G}==${N} ${G}全部依赖已就绪${N}\n\n"
info "下一步:"
info "  1. 把 VPNMenuBar.app 拖到 /Applications"
info "  2. 首次打开:右键点击 .app → 选'打开' → 警告框里再次点'打开'"
info "  3. 按状态栏弹出的 Onboarding 向导填写 VPN 用户名 / 密码前缀 / TOTP 密钥"
info ""
info "如果以后想卸载 sudoers 规则,执行:"
info "  sudo rm $SUDOERS_FILE"
