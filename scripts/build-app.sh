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
#   .build/app/SyncClipboard.app           .app 目录（PlugIns/ 里带两个 appex）
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
    *) echo "未知 arch: ${ARCH}" >&2; exit 1 ;;
esac

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Config/Info.plist)"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' Config/Info.plist)"

# M4/M5 两个扩展：SwiftPM target 名 / 打包用的 Info.plist 与 entitlements
SHARE_EXT="ShareExt"
SHARE_EXT_PLIST="Config/ShareExt-Info.plist"
SHARE_EXT_ENT="Config/ShareExt.entitlements"
KEYBOARD_EXT="KeyboardExt"
KEYBOARD_EXT_PLIST="Config/KeyboardExt-Info.plist"
KEYBOARD_EXT_ENT="Config/KeyboardExt.entitlements"

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "找不到 iPhoneOS SDK。需要装 Xcode（只有 Command Line Tools 不够）。" >&2
    exit 1
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

echo "==> 构建 ${APP_NAME} ${VERSION}  目标 ${TRIPLE}"
echo "==> SDK: ${SDK}"

# ---- 静态体检（本机就能跑的都在这一步拦掉）----
echo "==> 源码体检"
node scripts/lint-swift.js

echo "==> 生成图标"
node scripts/make-icons.js Resources

# ---- 构建 ----
# 不用 Xcode 工程：SwiftPM 直接交叉编译到 iOS。
# 关掉代码签名，因为我们要自己用 ldid 写私有 entitlement，让两边一起插手会互相覆盖。
# 三个 product（主 App + 两个 appex）逐个构建：同一个 scratch path，SyncClipCore
# 等公共依赖只编译一次，后面的 product 增量跑。
build_product() {
    local product="$1"
    echo "==> swift build --product ${product}"
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
build_product "$SHARE_EXT"
build_product "$KEYBOARD_EXT"

BIN_DIR="$(swift build -c release --triple "$TRIPLE" --sdk "$SDK" \
    --scratch-path .build/spm --show-bin-path)"

# SwiftPM 的产物名可能跟 product 或 target 同名，两个都试一下
find_bin() {
    local candidate
    for candidate in "$@"; do
        if [ -f "$BIN_DIR/$candidate" ]; then
            echo "$BIN_DIR/$candidate"
            return 0
        fi
    done
    return 1
}

BUILT="$(find_bin "$APP_NAME" SyncClipboardApp syncclip || true)"
SHARE_BIN="$(find_bin "$SHARE_EXT" || true)"
KEYBOARD_BIN="$(find_bin "$KEYBOARD_EXT" || true)"
if [ -z "$BUILT" ] || [ -z "$SHARE_BIN" ] || [ -z "$KEYBOARD_BIN" ]; then
    echo "在 ${BIN_DIR} 里找不到构建产物。目录内容：" >&2
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

# ---- 组装两个 appex（照 build-probe.sh 对 PasteProbeTunnel 的做法）----
# appex 的最小合法形状：可执行文件 + 它自己的 Info.plist（NSExtension 字段）
# + PkgInfo。CFBundleExecutable 必须等于文件名，PlugInKit 靠它起进程。
make_appex() {
    local bin="$1" plist="$2" appex_dir="$3" exec_name="$4"
    rm -rf "$appex_dir"
    mkdir -p "$appex_dir"
    cp "$bin" "$appex_dir/$exec_name"
    chmod 755 "$appex_dir/$exec_name"
    cp "$plist" "$appex_dir/Info.plist"
    printf 'XPC!????' > "$appex_dir/PkgInfo"
}

SHARE_APPEX="$APP/PlugIns/${SHARE_EXT}.appex"
KEYBOARD_APPEX="$APP/PlugIns/${KEYBOARD_EXT}.appex"
make_appex "$SHARE_BIN" "$SHARE_EXT_PLIST" "$SHARE_APPEX" "$SHARE_EXT"
make_appex "$KEYBOARD_BIN" "$KEYBOARD_EXT_PLIST" "$KEYBOARD_APPEX" "$KEYBOARD_EXT"

echo "==> .app 内容："
(cd "$APP" && find . -type f | sort | sed 's/^/    /')
echo "==> 架构：$(lipo -archs "$APP/$APP_NAME" 2>/dev/null || file "$APP/$APP_NAME")"

# ---- ldid 签名 ----
# 这一步是整个方案的命门：TrollStore 会把 IPA 里的 entitlement 原样保留并被系统承认，
# 所以「读剪贴板不弹提示」完全取决于这里有没有把 entitlement 写进二进制。
# 顺序有讲究：先签 appex 再签宿主 App（宿主的签名覆盖整个 bundle，反过来的话
# appex 的签名会被后续步骤动到）—— 与 build-probe.sh 的做法一致。
sign_appex() {
    local ent="$1" appex_bin="$2" label="$3"
    echo "==> ldid 签名 ${label}（${ent}）"
    ldid -S"$ent" "$appex_bin"
    local ent_out
    ent_out="$(ldid -e "$appex_bin")"
    echo "==> ${label} 签名内 entitlement 复核："
    echo "$ent_out" | sed 's/^/    /'
    if ! echo "$ent_out" | grep -q "group.com.cxk.syncclip"; then
        echo "!! 致命：${label} 的 entitlement 里缺 App Group（group.com.cxk.syncclip）。" >&2
        exit 1
    fi
}

if [ "$SIGN" = "1" ]; then
    if ! command -v ldid >/dev/null 2>&1; then
        echo "!! 找不到 ldid。装一个（brew install libplist && 从 ProcursusTeam/ldid 源码 make）。" >&2
        exit 1
    fi
    sign_appex "$SHARE_EXT_ENT" "$SHARE_APPEX/$SHARE_EXT" "分享 appex"
    sign_appex "$KEYBOARD_EXT_ENT" "$KEYBOARD_APPEX/$KEYBOARD_EXT" "键盘 appex"

    echo "==> ldid 签名宿主 App（Config/SyncClipboard.entitlements）"
    ldid -SConfig/SyncClipboard.entitlements "$APP/$APP_NAME"

    ENT="$(ldid -e "$APP/$APP_NAME")"
    echo "==> 签名内 entitlement 复核："
    echo "$ENT" | sed 's/^/    /'
    for key in com.apple.private.webkit.pasteboard \
               com.apple.Pasteboard.background-access \
               com.apple.private.pasteboard.check-pasteboard \
               com.apple.Pasteboard.paste-unchecked \
               group.com.cxk.syncclip; do
        if ! echo "$ENT" | grep -q "$key"; then
            echo "!! 致命：entitlement 里缺 ${key}。装上去功能会哑掉。" >&2
            exit 1
        fi
    done
else
    echo "==> 按 --no-sign 跳过签名（打出来的 ipa 不要装到真机）"
fi

# ---- 验 appex 入口点（照 build-probe.sh）----
# SwiftPM 没有 app-extension 产品类型，入口点靠链接器的 -e _NSExtensionMain。
# 它没生效的话 appex 会「静默什么都不做」，现象和 entitlement 没生效一模一样，
# 所以在打 ipa 之前就验掉，别带上真机。
check_entry_point() {
    local appex_bin="$1" label="$2"
    local entry
    entry="$(otool -l "$appex_bin" | awk '/LC_MAIN/{found=1} found&&/entryoff/{print $2; exit}')"
    if [ -z "$entry" ]; then
        echo "!! ${label} 没有 LC_MAIN（苹果的 appex 应该有）" >&2
        exit 1
    fi
    if ! nm -u "$appex_bin" | grep -q '_NSExtensionMain'; then
        echo "!! ${label} 没有引用 _NSExtensionMain —— 入口点没被接上" >&2
        exit 1
    fi
    echo "    ${label}：LC_MAIN entryoff=${entry}，且引用了 _NSExtensionMain"
}

echo "==> 检查 appex 入口点"
check_entry_point "$SHARE_APPEX/$SHARE_EXT" "分享 appex"
check_entry_point "$KEYBOARD_APPEX/$KEYBOARD_EXT" "键盘 appex"

# ---- 打 ipa 并验包 ----
IPA="dist/SyncClipboard_${VERSION}.ipa"
echo "==> 打 ipa"
node scripts/make-ipa.js "$APP_NAME" "$APP" "$IPA"

echo "==> 验包（app-full 档：四条剪贴板 entitlement + App Group + 两个 appex）"
node scripts/verify-ipa.js "$IPA" --profile app-full

echo
echo "完成：$IPA"
echo
echo "装到设备：把 ipa 传到 iPhone，用 TrollStore 打开安装。"
echo "装完先在 App 的「诊断」页确认：地基层显示「剪贴板权限就位」。"
echo "分享扩展在系统分享菜单里；键盘在 设置-通用-键盘-键盘-添加新键盘。"
