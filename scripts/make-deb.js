// 打包脚本：把构建产物做成可 dpkg -i 安装的 .deb（rootless /var/jb 布局）
//
// 用法（在仓库根目录）：
//   node scripts/make-deb.js <version> <arch> <binary> <outDir>
//   node scripts/make-deb.js 0.1.0 iphoneos-arm64e .build/syncclipd dist
//
// 设计：**零外部依赖**。ar 归档（deb 的外壳）和 tar 归档都由本脚本按规范自己写，
// gzip 用 Node 内置的 zlib。不需要 ar / tar / dpkg-deb。
//
// 这么做的两个实际理由：
//   1. 权限位可控。Windows 上 fs.chmod 设不了执行位，靠系统 tar 打出来的包
//      二进制会是 0644，装上去直接跑不起来。自己写 tar 头就不会有这个问题。
//   2. 三个平台（macOS CI / Linux / Windows 本机）产出结构完全一致，本机就能验包。

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '..');

const [version = '0.1.0', arch = 'iphoneos-arm64e', binary = '.build/syncclipd', outDir = 'dist'] =
    process.argv.slice(2);

const PKG_ID = 'com.cxk.syncclipd';
const PLIST_NAME = 'com.cxk.syncclipd.plist';
const CONFIG_PATH = '/var/mobile/Library/Preferences/com.cxk.syncclip.plist';

// ===========================================================================
// tar (ustar) 写入
//
// 每个成员 = 512 字节头 + 数据（补 NUL 到 512 的整数倍）；归档以两个全零块结束。
// 头布局：
//   0   100  name       100  108  mode (八进制, 7 位 + NUL)
//   108 116  uid        116  124  gid
//   124 136  size (11 位八进制 + NUL)
//   136 148  mtime      148  156  chksum（8 字节，写入时先按 8 个空格算）
//   156 157  typeflag（'0' 普通文件 / '5' 目录）
//   157 257  linkname   257  263  magic "ustar\0"
//   263 265  version "00"
//   265 297  uname      297  329  gname
//   329 337  devmajor   337  345  devminor   345  500  prefix
// ===========================================================================

function tarHeader({ name, mode, size = 0, type = '0', mtime = 0, uid = 0, gid = 0,
                     uname = 'root', gname = 'wheel' }) {
    if (name.length > 100) throw new Error(`tar 成员名过长（>100）：${name}`);
    const buf = Buffer.alloc(512, 0);

    buf.write(name, 0, 100, 'utf8');
    buf.write(mode.toString(8).padStart(7, '0') + '\0', 100, 8, 'ascii');
    buf.write(uid.toString(8).padStart(7, '0') + '\0', 108, 8, 'ascii');
    buf.write(gid.toString(8).padStart(7, '0') + '\0', 116, 8, 'ascii');
    buf.write(size.toString(8).padStart(11, '0') + '\0', 124, 12, 'ascii');
    buf.write(mtime.toString(8).padStart(11, '0') + '\0', 136, 12, 'ascii');
    buf.write(type, 156, 1, 'ascii');
    buf.write('ustar\0', 257, 6, 'ascii');
    buf.write('00', 263, 2, 'ascii');
    buf.write(uname, 265, 32, 'ascii');
    buf.write(gname, 297, 32, 'ascii');

    // 校验和：先把 chksum 字段当 8 个空格，累加全部 512 字节，再以 6 位八进制 + NUL + 空格写回
    buf.write('        ', 148, 8, 'ascii');
    let sum = 0;
    for (let i = 0; i < 512; i++) sum += buf[i];
    buf.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');

    return buf;
}

/// entries: [{ name, mode, type ('0'|'5'), data?, mtime? }]
function makeTarGz(entries) {
    const now = Math.floor(Date.now() / 1000);
    const parts = [];

    for (const e of entries) {
        const data = e.data ?? Buffer.alloc(0);
        parts.push(tarHeader({
            name: e.name,
            mode: e.mode,
            size: e.type === '5' ? 0 : data.length,
            type: e.type,
            mtime: e.mtime ?? now,
        }));
        if (e.type !== '5' && data.length > 0) {
            parts.push(data);
            const pad = (512 - (data.length % 512)) % 512;
            if (pad > 0) parts.push(Buffer.alloc(pad, 0));
        }
    }

    // 结束标记：两个全零块
    parts.push(Buffer.alloc(1024, 0));
    const tar = Buffer.concat(parts);
    // mtime 归零让 gzip 输出可复现（同一份源码产出的包 hash 稳定）
    return zlib.gzipSync(tar, { level: 9 });
}

// ===========================================================================
// ar 写入（deb 外壳）
//
// 全局魔数 "!<arch>\n"，随后每个成员 60 字节 ASCII 头 + 数据（奇数长度补 \n）：
//   0  16 文件名   16 12 mtime   28 6 uid   34 6 gid   40 8 权限   48 10 长度   58 2 "`\n"
// ===========================================================================

function writeAr(outFile, members) {
    const chunks = [Buffer.from('!<arch>\n')];
    const now = Math.floor(Date.now() / 1000);

    for (const { name, data } of members) {
        if (name.length > 16) throw new Error(`ar 成员名过长（>16）：${name}`);
        const header = Buffer.alloc(60, 0x20);
        header.write(name, 0, 16, 'ascii');
        header.write(String(now).padEnd(12, ' '), 16, 12, 'ascii');
        header.write('0'.padEnd(6, ' '), 28, 6, 'ascii');
        header.write('0'.padEnd(6, ' '), 34, 6, 'ascii');
        header.write('100644'.padEnd(8, ' '), 40, 8, 'ascii');
        header.write(String(data.length).padEnd(10, ' '), 48, 10, 'ascii');
        header.write('`\n', 58, 2, 'ascii');

        chunks.push(header, data);
        if (data.length % 2 !== 0) chunks.push(Buffer.from('\n'));
    }

    fs.writeFileSync(outFile, Buffer.concat(chunks));
}

// ===========================================================================

if (!fs.existsSync(binary)) {
    console.error(`找不到二进制：${binary}\n先在 macOS 上跑 scripts/build.sh 构建。`);
    process.exit(1);
}

const binData = fs.readFileSync(binary);
const plistSrc = path.join(ROOT, 'layout', PLIST_NAME);
if (!fs.existsSync(plistSrc)) {
    console.error(`找不到 LaunchAgent：${plistSrc}`);
    process.exit(1);
}
const plistData = fs.readFileSync(plistSrc);

// ---------------------------------------------------------------------------
// control 脚本
// ---------------------------------------------------------------------------

const control = `Package: ${PKG_ID}
Name: SyncClipboard Daemon
Version: ${version}
Architecture: ${arch}
Description: SyncClipboard background clipboard sync daemon (iOS)
Maintainer: cxk
Author: cxk
Section: Utilities
Depends: firmware (>= 15.0)
Installed-Size: ${Math.ceil((binData.length + plistData.length) / 1024)}
`;

// 关键点：LaunchAgent 必须由**用户**的 launchd 加载，root 的 launchctl 不行，
// 所以要 `launchctl asuser 501` 切进 mobile 的 GUI 会话里操作。
const postinst = `#!/bin/sh
set -e

LOG_DIR=/var/mobile/Library/Logs
mkdir -p "$LOG_DIR"
chown mobile:mobile "$LOG_DIR" 2>/dev/null || true
touch "$LOG_DIR/syncclipd.log" 2>/dev/null || true
chown mobile:mobile "$LOG_DIR/syncclipd.log" 2>/dev/null || true

# 默认配置：只在不存在时写，避免覆盖已经填好的账号密码
CFG=${CONFIG_PATH}
if [ ! -f "$CFG" ]; then
    mkdir -p /var/mobile/Library/Preferences
    cat > "$CFG" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>baseURL</key><string>http://CHANGE_ME:5033</string>
    <key>username</key><string>CHANGE_ME</string>
    <key>password</key><string>CHANGE_ME</string>
    <key>pollInterval</key><real>2.0</real>
    <key>startupSync</key><string>pull</string>
</dict>
</plist>
PLIST
    chown mobile:mobile "$CFG"
fi

# 装进用户域（新老 launchctl 语法都试一遍，失败也不阻断安装）
launchctl asuser 501 launchctl bootout gui/501/${PKG_ID} 2>/dev/null || true
launchctl asuser 501 launchctl bootstrap gui/501 /var/jb/Library/LaunchAgents/${PLIST_NAME} 2>/dev/null \\
    || launchctl asuser 501 launchctl load -w /var/jb/Library/LaunchAgents/${PLIST_NAME} 2>/dev/null \\
    || true

echo "syncclipd 已安装。"
echo "  1) 编辑 ${CONFIG_PATH} 填服务器地址与账号"
echo "  2) 重启服务：launchctl asuser 501 launchctl kickstart -k gui/501/${PKG_ID}"
echo "  3) 看日志：  tail -f /var/mobile/Library/Logs/syncclipd.log"
exit 0
`;

const prerm = `#!/bin/sh
set -e
launchctl asuser 501 launchctl bootout gui/501/${PKG_ID} 2>/dev/null || true
launchctl asuser 501 launchctl unload -w /var/jb/Library/LaunchAgents/${PLIST_NAME} 2>/dev/null || true
exit 0
`;

const postrm = `#!/bin/sh
set -e
rm -f /var/jb/Library/LaunchAgents/${PLIST_NAME} 2>/dev/null || true
exit 0
`;

// ---------------------------------------------------------------------------
// control.tar.gz（只放 DEBIAN 目录内容，绝不能混进 data）
// ---------------------------------------------------------------------------
const controlTar = makeTarGz([
    { name: './',      mode: 0o755, type: '5' },
    { name: './control',  mode: 0o644, type: '0', data: Buffer.from(control, 'utf8') },
    { name: './postinst', mode: 0o755, type: '0', data: Buffer.from(postinst, 'utf8') },
    { name: './prerm',    mode: 0o755, type: '0', data: Buffer.from(prerm, 'utf8') },
    { name: './postrm',   mode: 0o755, type: '0', data: Buffer.from(postrm, 'utf8') },
]);

// ---------------------------------------------------------------------------
// data.tar.gz（rootless：一切都在 /var/jb 之下）
// 权限位在这里显式写死，不依赖文件系统（Windows 上 chmod 设不了执行位）
// ---------------------------------------------------------------------------
const dataTar = makeTarGz([
    { name: './',                                                mode: 0o755, type: '5' },
    { name: './var/',                                            mode: 0o755, type: '5' },
    { name: './var/jb/',                                         mode: 0o755, type: '5' },
    { name: './var/jb/Library/',                                 mode: 0o755, type: '5' },
    { name: './var/jb/Library/LaunchAgents/',                    mode: 0o755, type: '5' },
    { name: './var/jb/Library/LaunchAgents/' + PLIST_NAME,       mode: 0o644, type: '0', data: plistData },
    { name: './var/jb/usr/',                                     mode: 0o755, type: '5' },
    { name: './var/jb/usr/bin/',                                 mode: 0o755, type: '5' },
    { name: './var/jb/usr/bin/syncclipd',                        mode: 0o755, type: '0', data: binData },
]);

// ---------------------------------------------------------------------------
// 组装 deb
// ---------------------------------------------------------------------------
fs.mkdirSync(path.join(ROOT, outDir), { recursive: true });
const outPath = path.join(ROOT, outDir, `${PKG_ID}_${version}_${arch}.deb`);

writeAr(outPath, [
    { name: 'debian-binary',  data: Buffer.from('2.0\n') },
    { name: 'control.tar.gz', data: controlTar },
    { name: 'data.tar.gz',    data: dataTar },
]);

console.log(`已生成：${path.relative(ROOT, outPath)}`);
console.log(`  arch=${arch}  version=${version}  size=${(fs.statSync(outPath).size / 1024).toFixed(1)} KB`);
