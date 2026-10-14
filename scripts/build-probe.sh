#!/bin/bash
# 构建「NE 可行性探针」并打成 TrollStore 可安装的 .ipa
#
# 必须在 macOS 上跑（需要 Xcode 的 iPhoneOS SDK + swiftc）。
#
#   scripts/build-probe.sh                 # arm64（兼容性最好）
#   scripts/build-probe.sh --arch arm64e
#   scripts/build-probe.sh --no-sign       # 只构建，不签名
#
# 产物：
#   .build/probe/PasteProbe.app                      App 目录
#   dist/PasteProbe_<version>_<arch>.ipa             TrollStore 直接装
#
# 这个包是干什么的：见 docs/probe.md。一句话 —— 它要回答
# 「非越狱设备上，伪造签名的网络扩展（VPN 隧道）能不能真的跑起来，
#   以及隧道进程能不能读写剪贴板」。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCH="arm64"
SIGN=1
for arg in "$@"; do
    case "$arg" in
        arm64|arm64e) ARCH="$arg" ;;
        --no-sign)    SIGN=0 ;;
    esac
done

case "$ARCH" in
    arm64)  TRIPLE="arm64-apple-ios15.0" ;;
    arm64e) TRIPLE="arm64e-apple-ios15.0" ;;
    *) echo "未知 arch: $ARCH" >&2; exit 1 ;;
esac

APP_NAME="PasteProbe"
TUNNEL_NAME="PasteProbeTunnel"
APP_PLIST="Config/PasteProbe-Info.plist"
APP_ENT="Config/PasteProbe.entitlements"
TUNNEL_PLIST="Config/PasteProbeTunnel-Info.plist"
TUNNEL_ENT="Config/PasteProbeTunnel.entitlements"

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "找不到 iPhoneOS SDK。需要装 Xcode（只有 Command Line Tools 不够）。" >&2
    exit 1
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"

echo "==> 构建 NE 探针 $VERSION  目标 $TRIPLE"
echo "==> SDK: $SDK"

# ---- 静态体检 ----
echo "==> 源码体检"
node scripts/lint-swift.js

echo "==> 生成图标"
node scripts/make-icons.js Resources

# ---- 构建两个 product ----
# 关掉代码签名（SwiftPM 默认也不签），我们要自己用 ldid 写私有 entitlement。
build_product() {
    local product="$1"
    echo "==> swift build --product $product"
    swift build \
        -c release \
        --triple "$TRIPLE" \
        --sdk "$SDK" \
        --scratch-path .build/spm \
        --product "$product" \
        -Xswiftc -Osize \
        -Xlinker -dead_strip
}

build_product "$APP_NAME"
build_product "$TUNNEL_NAME"

BIN_DIR="$(swift build -c release --triple "$TRIPLE" --sdk "$SDK" \
    --scratch-path .build/spm --show-bin-path)"

find_bin() {
    for candidate in "$@"; do
        if [ -f "$BIN_DIR/$candidate" ]; then echo "$BIN_DIR/$candidate"; return 0; fi
    done
    return 1
}

APP_BIN="$(find_bin "$APP_NAME" PasteProbe || true)"
TUNNEL_BIN="$(find_bin "$TUNNEL_NAME" || true)"
if [ -z "$APP_BIN" ] || [ -z "$TUNNEL_BIN" ]; then
    echo "在 $BIN_DIR 里找不到构建产物。目录内容：" >&2
    ls -la "$BIN_DIR" >&2
    exit 1
fi

# ---- 组装 .app（注意 appex 在 PlugIns/ 里）----
APP=".build/probe/$APP_NAME.app"
APPEX="$APP/PlugIns/$TUNNEL_NAME.appex"
rm -rf "$APP"
mkdir -p "$APPEX"

cp "$APP_BIN" "$APP/$APP_NAME"
chmod 755 "$APP/$APP_NAME"
cp "$APP_PLIST" "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
cp Resources/AppIcon60x60@2x.png "$APP/"
cp Resources/AppIcon60x60@3x.png "$APP/"

cp "$TUNNEL_BIN" "$APPEX/$TUNNEL_NAME"
chmod 755 "$APPEX/$TUNNEL_NAME"
cp "$TUNNEL_PLIST" "$APPEX/Info.plist"
printf 'XPC!????' > "$APPEX/PkgInfo"

echo "==> .app 内容："
(cd "$APP" && find . -type f | sort | sed 's/^/    /')
echo "==> 架构：$(lipo -archs "$APP/$APP_NAME" 2>/dev/null || file "$APP/$APP_NAME")"

# ---- ldid 签名 ----
# 顺序有讲究：先签 appex，再签宿主 App。宿主 App 的签名覆盖整个 bundle，
# 反过来的话 appex 的签名会被后续步骤动到。
if [ "$SIGN" = "1" ]; then
    if ! command -v ldid >/dev/null 2>&1; then
        echo "!! 找不到 ldid。先跑 scripts/setup-ldid.sh。" >&2
        exit 1
    fi

    echo "==> ldid 签名 appex（${TUNNEL_ENT}）"
    ldid -S"$TUNNEL_ENT" "$APPEX/$TUNNEL_NAME"
    TUNNEL_ENT_OUT="$(ldid -e "$APPEX/$TUNNEL_NAME")"

    echo "==> ldid 签名宿主 App（${APP_ENT}）"
    ldid -S"$APP_ENT" "$APP/$APP_NAME"
    APP_ENT_OUT="$(ldid -e "$APP/$APP_NAME")"

    echo "==> 签名内 entitlement 复核："
    echo "  [appex]" && echo "$TUNNEL_ENT_OUT" | sed 's/^/    /'
    echo "  [app]"   && echo "$APP_ENT_OUT"   | sed 's/^/    /'

    for key in com.apple.developer.networking.networkextension \
               com.apple.security.application-groups \
               com.apple.Pasteboard.background-access; do
        if ! echo "$TUNNEL_ENT_OUT" | grep -q "$key"; then
            echo "!! 致命：appex 的 entitlement 里缺 $key" >&2
            exit 1
        fi
        if ! echo "$APP_ENT_OUT" | grep -q "$key"; then
            echo "!! 致命：宿主 App 的 entitlement 里缺 $key" >&2
            exit 1
        fi
    done
else
    echo "==> 按 --no-sign 跳过签名（打出来的 ipa 不要装到真机）"
fi

# ---- 验入口点 ----
# 这是 appex 最容易错的一处：SwiftPM 没有 app-extension 产品类型，入口点得靠
# 链接器的 -e _NSExtensionMain。要是它没生效，appex 会在启动时"静默什么都不做"，
# 现象和 entitlement 没生效一模一样。所以在这里就把它验掉，别带上真机。
echo "==> 检查 appex 入口点"
ENTRY="$(otool -l "$APPEX/$TUNNEL_NAME" | awk '/LC_MAIN/{found=1} found&&/entryoff/{print $2; exit}')"
if [ -z "$ENTRY" ]; then
    echo "!! appex 没有 LC_MAIN（苹果的 appex 应该有；见 docs/probe.md）" >&2
    exit 1
fi
if ! nm -u "$APPEX/$TUNNEL_NAME" | grep -q '_NSExtensionMain'; then
    echo "!! appex 没有引用 _NSExtensionMain —— 入口点没被接上" >&2
    exit 1
fi
echo "    LC_MAIN entryoff=${ENTRY}，且引用了 _NSExtensionMain"

# ---- 打 ipa 并验包 ----
IPA="dist/PasteProbe_${VERSION}_${ARCH}.ipa"
echo "==> 打 ipa"
node scripts/make-ipa.js "$APP_NAME" "$APP" "$IPA"

echo "==> 验包（probe 档：appex 入口点 / 两组 entitlement / 无后台模式）"
node scripts/verify-ipa.js "$IPA" --profile probe

echo
echo "完成：$IPA"
echo
echo "装到设备：把 ipa 传到 iPhone，用 TrollStore 打开安装，然后看 docs/probe.md 的操作步骤。"
