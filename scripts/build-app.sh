#!/bin/bash
# 构建 iOS App 并打成 TrollStore 可安装的 .ipa
#
# 必须在 macOS 上跑（需要 Xcode 的 iPhoneOS SDK + swiftc）。用法：
#
#   scripts/build-app.sh                 # 构建 + 签名 + 打 ipa + 验包
#   scripts/build-app.sh --no-sign       # 只构建，不 ldid 签名
#   scripts/build-app.sh --arch arm64e   # 给 arm64e 构建（默认 arm64，兼容性最好）
#
# 产物：
#   .build/app/SyncClipboard.app           .app 目录
#   dist/SyncClipboard_<version>.ipa       TrollStore 直接装

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

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Config/Info.plist)"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' Config/Info.plist)"

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "找不到 iPhoneOS SDK。需要装 Xcode（只有 Command Line Tools 不够）。" >&2
    exit 1
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

echo "==> 构建 $APP_NAME $VERSION  目标 $TRIPLE"
echo "==> SDK: $SDK"

# ---- 静态体检（本机就能跑的都在这一步拦掉）----
echo "==> 源码体检"
node scripts/lint-swift.js

echo "==> 生成图标"
node scripts/make-icons.js Resources

# ---- 构建 ----
# 不用 Xcode 工程：SwiftPM 直接交叉编译到 iOS。
# 关掉代码签名，因为我们要自己用 ldid 写私有 entitlement，让两边一起插手会互相覆盖。
echo "==> swift build"
swift build \
    -c release \
    --triple "$TRIPLE" \
    --sdk "$SDK" \
    --scratch-path .build/spm \
    --product "$APP_NAME" \
    -Xswiftc -Osize \
    -Xlinker -dead_strip

BIN_DIR="$(swift build -c release --triple "$TRIPLE" --sdk "$SDK" \
    --scratch-path .build/spm --show-bin-path)"

# SwiftPM 的产物名可能跟 product 或 target 同名，两个都试一下
BUILT=""
for candidate in "$APP_NAME" "SyncClipApp" "syncclip"; do
    if [ -f "$BIN_DIR/$candidate" ]; then BUILT="$BIN_DIR/$candidate"; break; fi
done
if [ -z "$BUILT" ]; then
    echo "在 $BIN_DIR 里找不到构建产物。目录内容：" >&2
    ls -la "$BIN_DIR" >&2
    exit 1
fi

# ---- 组装 .app ----
APP=".build/app/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP"

cp "$BUILT" "$APP/$APP_NAME"
chmod 755 "$APP/$APP_NAME"
cp Config/Info.plist "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"

# 图标：直接放 PNG，不用 Assets.xcassets（那需要 actool，会引入 Xcode 工程依赖）
cp Resources/AppIcon60x60@2x.png "$APP/"
cp Resources/AppIcon60x60@3x.png "$APP/"

echo "==> .app 内容："
ls -la "$APP" | sed 's/^/    /'
echo "==> 架构：$(lipo -archs "$APP/$APP_NAME" 2>/dev/null || file "$APP/$APP_NAME")"

# ---- ldid 签名 ----
# 这一步是整个方案的命门：TrollStore 会把 IPA 里的 entitlement 原样保留并被系统承认，
# 所以「读剪贴板不弹提示」完全取决于这里有没有把 entitlement 写进二进制。
if [ "$SIGN" = "1" ]; then
    if ! command -v ldid >/dev/null 2>&1; then
        echo "!! 找不到 ldid。装一个（brew install libplist && 从 ProcursusTeam/ldid 源码 make）。" >&2
        exit 1
    fi
    echo "==> ldid 签名（Config/SyncClipboard.entitlements）"
    ldid -SConfig/SyncClipboard.entitlements "$APP/$APP_NAME"

    ENT="$(ldid -e "$APP/$APP_NAME")"
    echo "==> 签名内 entitlement 复核："
    echo "$ENT" | sed 's/^/    /'
    for key in com.apple.private.webkit.pasteboard \
               com.apple.Pasteboard.background-access \
               com.apple.private.pasteboard.check-pasteboard \
               com.apple.Pasteboard.paste-unchecked; do
        if ! echo "$ENT" | grep -q "$key"; then
            echo "!! 致命：entitlement 里缺 ${key}。装上去读剪贴板会弹提示或被拒。" >&2
            exit 1
        fi
    done
else
    echo "==> 按 --no-sign 跳过签名（打出来的 ipa 不要装到真机）"
fi

# ---- 打 ipa 并验包 ----
IPA="dist/SyncClipboard_${VERSION}.ipa"
echo "==> 打 ipa"
node scripts/make-ipa.js "$APP_NAME" "$APP" "$IPA"

echo "==> 验包（含从 Mach-O 签名段复读 entitlement）"
node scripts/verify-ipa.js "$IPA"

echo
echo "完成：$IPA"
echo
echo "装到设备：把 ipa 传到 iPhone，用 TrollStore 打开安装。"
echo "装完先在 App 的「诊断」页确认：地基层显示「剪贴板权限就位」。"
