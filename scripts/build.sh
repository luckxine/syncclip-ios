#!/bin/bash
# 构建脚本（必须在 macOS 上跑，需要 Xcode / SwiftPM / ldid）
#
# 用法：
#   scripts/build.sh                    # 构建 arm64e（A12 及以后）+ 签名 + 打 deb
#   scripts/build.sh arm64              # 构建 arm64（A11 及更早 / checkm8 机型）
#   scripts/build.sh arm64e --no-sign   # 只构建不签名
#
# 产物：
#   .build/syncclipd                                   已签名二进制
#   dist/com.cxk.syncclipd_<version>_<debarch>.deb     可 dpkg -i 安装

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCH="arm64e"
SIGN=1
for arg in "$@"; do
    case "$arg" in
        arm64|arm64e) ARCH="$arg" ;;
        --no-sign)    SIGN=0 ;;
        --arm64)      ARCH="arm64" ;;
    esac
done

case "$ARCH" in
    arm64e) TRIPLE="arm64e-apple-ios15.0"; DEB_ARCH="iphoneos-arm64e" ;;
    arm64)  TRIPLE="arm64-apple-ios15.0";  DEB_ARCH="iphoneos-arm64"  ;;
    *) echo "未知 arch: ${ARCH}（只支持 arm64 / arm64e）" >&2; exit 1 ;;
esac

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :version' layout/Info.plist 2>/dev/null || echo 0.0.0)"

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "找不到 iPhoneOS SDK。需要装 Xcode（只有 Command Line Tools 不够）。" >&2
    exit 1
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

echo "==> 版本 $VERSION   目标 $TRIPLE   deb arch $DEB_ARCH"
echo "==> SDK: $SDK"

# ---- 静态体检 ----
# 本机就把结构性错误拦掉，别浪费 CI 的排队时间
echo "==> 源码体检"
node scripts/lint-swift.js || exit 1

# ---- 构建 ----
# 不用 Xcode 工程，直接让 SwiftPM 交叉编译到 iOS。
# 不开 Xcode 的代码签名：我们要自己用 ldid 写私有 entitlement，两边一起插手会互相覆盖。
echo "==> swift build"
swift build \
    -c release \
    --triple "$TRIPLE" \
    --sdk "$SDK" \
    --scratch-path .build/spm \
    --product syncclipd \
    -Xswiftc -Osize \
    -Xlinker -dead_strip

BIN_DIR="$(swift build -c release --triple "$TRIPLE" --sdk "$SDK" \
    --scratch-path .build/spm --show-bin-path)"
if [ ! -f "$BIN_DIR/syncclipd" ]; then
    echo "构建产物不存在：$BIN_DIR/syncclipd" >&2
    exit 1
fi

mkdir -p .build
cp "$BIN_DIR/syncclipd" .build/syncclipd
chmod 755 .build/syncclipd
echo "==> 构建完成：$(stat -f%z .build/syncclipd) 字节"

# ---- 架构自检 ----
echo "==> 产物架构：$(lipo -archs .build/syncclipd 2>/dev/null || file .build/syncclipd)"

# ---- 签名 ----
# ldid 把 entitlements 写进二进制的签名段。
# 越狱环境（Dopamine rootless）通过 dynamic trustcache 放行 /var/jb 下 ad-hoc 签名
# 且带 entitlement 的二进制 —— 这一步就是「无提示读剪贴板」的开关。
if [ "$SIGN" = "1" ]; then
    if command -v ldid >/dev/null 2>&1; then
        echo "==> ldid 签名（layout/syncclipd.entitlements）"
        ldid -Slayout/syncclipd.entitlements .build/syncclipd

        echo "==> 签名内 entitlement 复核："
        ENT="$(ldid -e .build/syncclipd)"
        echo "$ENT" | sed 's/^/    /'
        for key in com.apple.private.webkit.pasteboard com.apple.Pasteboard.background-access \
                   com.apple.private.security.no-sandbox; do
            if ! echo "$ENT" | grep -q "$key"; then
                echo "!! 警告：entitlement 里缺少 ${key}，装上去读剪贴板会弹提示或被拒。" >&2
                exit 1
            fi
        done
    else
        echo "!! 找不到 ldid，跳过签名。" >&2
        echo "!! 装到设备上会因为缺少 entitlement 而无法无提示读写剪贴板。" >&2
        exit 1
    fi
else
    echo "==> 按 --no-sign 跳过签名"
fi

# ---- 打 deb ----
echo "==> 打 deb"
node scripts/make-deb.js "$VERSION" "$DEB_ARCH" .build/syncclipd dist

DEB="dist/com.cxk.syncclipd_${VERSION}_${DEB_ARCH}.deb"

# ---- 验包 ----
# 不需要 ar / dpkg-deb：verify-deb.js 自己按规范解析 deb，
# 会逐项确认 ar 成员顺序、control 字段、二进制权限位（最容易被漏的一项）等等。
echo "==> 校验 deb 结构"
node scripts/verify-deb.js "$DEB" || exit 1
echo
echo "完成：$DEB"
echo
echo "安装到设备："
echo "  scp \"$DEB\" root@<设备IP>:/var/mobile/Documents/"
echo "  ssh root@<设备IP> \"dpkg -i /var/mobile/Documents/$(basename "$DEB")\""
