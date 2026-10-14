#!/bin/bash
# 准备一个**功能可用**的 ldid。
#
# 为什么不能只 `brew install ldid` 就完事：ldid 是整个方案的命门
# （它把 entitlement 写进二进制，决定「读剪贴板弹不弹提示」），
# 而「装上了」和「能用」是两件事。所以这里每个候选都跑一次**功能冒烟测试**：
# 真的去签一个 Mach-O、再把 entitlement 读回来、确认内容对得上。
# 只有通过冒烟测试的才被采纳；全都不行就带着诊断信息失败，而不是继续往下走。
#
# 用法：scripts/setup-ldid.sh
# 成功后 ldid 在 PATH 里可用。

set -uo pipefail

SMOKE_DIR="$(mktemp -d)"
SMOKE_PLIST="$SMOKE_DIR/probe.entitlements"
SMOKE_TARGET="$SMOKE_DIR/probe"

cat > "$SMOKE_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.cxk.smoketest.marker</key>
	<true/>
</dict>
</plist>
PLIST

cleanup() { rm -rf "$SMOKE_DIR"; }
trap cleanup EXIT

# 冒烟测试：签名 → 读回 → 内容对得上
smoke_test() {
    local bin="$1"
    [ -x "$bin" ] || return 1

    # 造一个孤立的 Mach-O 副本：直接拿系统二进制当靶子（不改原文件）
    cp "$(xcrun --find nm 2>/dev/null || echo /bin/ls)" "$SMOKE_TARGET" 2>/dev/null || cp /bin/ls "$SMOKE_TARGET"

    if ! "$bin" -S"$SMOKE_PLIST" "$SMOKE_TARGET" >/dev/null 2>&1; then
        echo "      签名失败"
        return 1
    fi

    local dumped
    if ! dumped="$("$bin" -e "$SMOKE_TARGET" 2>/dev/null)"; then
        echo "      -e 读回失败"
        return 1
    fi

    if ! echo "$dumped" | grep -q 'com.cxk.smoketest.marker'; then
        echo "      读回的 entitlement 里没有我们写进去的标记"
        return 1
    fi

    return 0
}

try_candidate() {
    local label="$1" bin="$2"
    echo "==> 候选：$label"
    if smoke_test "$bin"; then
        echo "    ✅ 冒烟测试通过：$("$bin" -v 2>&1 | head -1)"
        CANDIDATE="$bin"
        return 0
    fi
    echo "    ✗ 不可用"
    return 1
}

# 采纳：保证 ldid 在 /usr/local/bin 里（workflow 会把它加进 PATH）
adopt() {
    local bin="$1"
    local resolved
    resolved="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")"
    if [ "$resolved" != "/usr/local/bin/ldid" ]; then
        sudo mkdir -p /usr/local/bin
        sudo install -m 755 "$bin" /usr/local/bin/ldid
        echo "    已安装到 /usr/local/bin/ldid"
    fi
    exit 0
}

CANDIDATE=""

# ---------- 候选 1：PATH 里已有的 ----------
if command -v ldid >/dev/null 2>&1; then
    if try_candidate "PATH 里已有的 ldid" "$(command -v ldid)"; then
        echo "ldid 可用：$CANDIDATE"
        exit 0
    fi
fi
# ---------- 候选 2：Homebrew bottle（最快，通常就是它）----------
echo "==> 试 Homebrew 的 ldid"
if brew install ldid >/dev/null 2>&1 && command -v ldid >/dev/null 2>&1; then
    if try_candidate "Homebrew ldid" "$(command -v ldid)"; then
        echo "ldid 可用：$CANDIDATE"
        exit 0
    fi
fi

# ---------- 候选 3：从源码构建 ----------
# 注意：新版 clang 不再传递提供 <cstring>，而 ProcursusTeam/ldid 的 ldid.cpp
# 依赖它带来 memset/strlen/strerror。不修的话会报一堆 "use of undeclared identifier"。
# 用 -include 强制先包含，比打 ctx diff 更稳（不依赖源码行号）。
echo "==> 试从源码构建 ProcursusTeam/ldid"
SRC=/tmp/ldid-src
rm -rf "$SRC"
if brew install libplist openssl@3 >/dev/null 2>&1 &&
   git clone --depth 1 https://github.com/ProcursusTeam/ldid.git "$SRC" >/dev/null 2>&1; then

    OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null)"
    PLIST_PREFIX="$(brew --prefix libplist 2>/dev/null)"

    if ( cd "$SRC" && make -j"$(sysctl -n hw.ncpu)" \
            CPPFLAGS="-include cstring -include cstdio -include cstdlib" \
            LIBPLIST_INCLUDES="-I$PLIST_PREFIX/include -I$PLIST_PREFIX/include/plist" \
            LIBPLIST_LIBS="-L$PLIST_PREFIX/lib -lplist-2.0" \
            LIBCRYPTO_INCLUDES="-I$OPENSSL_PREFIX/include" \
            LIBCRYPTO_LIBS="-L$OPENSSL_PREFIX/lib -lcrypto" >/dev/null 2>&1 ); then
        if try_candidate "源码构建的 ldid" "$SRC/ldid"; then
            adopt "$CANDIDATE"
        fi
    else
        echo "    构建失败。错误摘要："
        ( cd "$SRC" && make -j1 CPPFLAGS="-include cstring -include cstdio -include cstdlib" \
            LIBPLIST_INCLUDES="-I$PLIST_PREFIX/include -I$PLIST_PREFIX/include/plist" \
            LIBPLIST_LIBS="-L$PLIST_PREFIX/lib -lplist-2.0" \
            LIBCRYPTO_INCLUDES="-I$OPENSSL_PREFIX/include" \
            LIBCRYPTO_LIBS="-L$OPENSSL_PREFIX/lib -lcrypto" 2>&1 | grep -E 'error:' | head -15 | sed 's/^/      /' )
    fi
fi

echo
echo "!! 没有一个可用的 ldid。" >&2
echo "!! entitlement 签不进去，打出来的 ipa 装到手机上读剪贴板会弹提示 —— 这种情况不该继续。" >&2
echo "!! 环境诊断：" >&2
echo "     sw_vers: $(sw_vers -productVersion 2>/dev/null)" >&2
echo "     clang:   $(clang --version 2>/dev/null | head -1)" >&2
echo "     brew:    $(brew --version 2>/dev/null | head -1)" >&2
exit 1
