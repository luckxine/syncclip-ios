// 把 .app 目录打成 TrollStore 能装的 .ipa（就是一个 zip）。
//
//   node scripts/make-ipa.js <AppName> <app目录> <输出文件>
//   node scripts/make-ipa.js SyncClipboard .build/app/SyncClipboard.app dist/SyncClipboard.ipa
//
// 自带 zip 写入器（deflate + CRC32），不依赖系统 zip 命令：
//   1. TrollStore 会保留可执行位等 unix 权限，而 Windows/macOS 的 zip 命令
//      在这件事上行为不一致；自己写 zip 头能精确控制 external attributes。
//   2. 三个平台的产物结构完全一致，本机（无 macOS）也能把包验一遍。

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const [appName = 'SyncClipboard', appDir = '.build/app/SyncClipboard.app', outFile = 'dist/SyncClipboard.ipa'] =
    process.argv.slice(2);

if (!fs.existsSync(appDir)) {
    console.error(`找不到 .app 目录：${appDir}\n先在 macOS 上跑 scripts/build-app.sh 构建。`);
    process.exit(1);
}
if (!fs.statSync(appDir).isDirectory()) {
    console.error(`${appDir} 不是目录`);
    process.exit(1);
}

// ---- CRC32 ----
const CRC_TABLE = (() => {
    const t = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
        t[n] = c;
    }
    return t;
})();

function crc32(buf) {
    let c = 0xffffffff;
    for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
}

// ---- 收集文件（固定 mtime，让同一份源码产出的 ipa 可复现）----
const DOS_TIME = 0;      // 00:00:00
const DOS_DATE = ((2024 - 1980) << 9) | (1 << 5) | 1;   // 2024-01-01

function walk(dir, base = '') {
    const out = [];
    for (const name of fs.readdirSync(dir).sort()) {
        if (name === '.DS_Store') continue;
        const full = path.join(dir, name);
        const rel = base ? `${base}/${name}` : name;
        const st = fs.lstatSync(full);
        if (st.isDirectory()) {
            out.push(...walk(full, rel));
        } else if (st.isFile()) {
            out.push({ full, rel, mode: st.mode & 0o777 });
        }
    }
    return out;
}

const files = walk(appDir);
if (files.length === 0) {
    console.error('.app 目录是空的');
    process.exit(1);
}

// ---- 需要保留可执行位的文件 ----
// 名单从**所有** Info.plist 里的 CFBundleExecutable 收集，而不是只看顶层那一个。
// 一个包里还可能有 appex（PlugIns/*.appex），它有自己的 CFBundleExecutable；
// 漏掉的话 appex 二进制会拿到 0644，装到设备上 PluginKit 根本起不来，
// 而且失败现象很含糊（和 entitlement 没生效长得一样）。
const execNames = new Set();
for (const f of files) {
    if (path.basename(f.rel) !== 'Info.plist') continue;
    try {
        const plist = fs.readFileSync(f.full, 'utf8');
        const m = plist.match(/<key>CFBundleExecutable<\/key>\s*<string>([^<]+)<\/string>/);
        if (m) execNames.add(m[1]);
    } catch { /* 读不了的话下面会被校验拦下 */ }
}
if (execNames.size === 0) execNames.add(appName);

const entries = files.map((f) => {
    const data = fs.readFileSync(f.full);
    const isExec = execNames.has(path.basename(f.rel));
    return {
        name: `Payload/${appName}.app/${f.rel}`,
        data,
        // unix 权限放进 external attributes 的高 16 位
        mode: (isExec ? 0o100755 : 0o100644),
    };
});

// ---- 写 zip ----
const localParts = [];
const centralParts = [];
let offset = 0;

for (const e of entries) {
    const crc = crc32(e.data);
    const compressed = zlib.deflateRawSync(e.data, { level: 9 });
    // 压不动就直接存（例如已经压过的 png）
    const useStore = compressed.length >= e.data.length;
    const method = useStore ? 0 : 8;
    const payload = useStore ? e.data : compressed;
    const nameBuf = Buffer.from(e.name, 'utf8');

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);                 // version needed
    local.writeUInt16LE(0, 6);                  // flags
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(DOS_TIME, 10);
    local.writeUInt16LE(DOS_DATE, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(payload.length, 18);
    local.writeUInt32LE(e.data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);                 // extra len

    localParts.push(local, nameBuf, payload);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(0x031e, 4);           // version made by: unix / 3.0
    central.writeUInt16LE(20, 6);               // version needed
    central.writeUInt16LE(0, 8);                // flags
    central.writeUInt16LE(method, 10);
    central.writeUInt16LE(DOS_TIME, 12);
    central.writeUInt16LE(DOS_DATE, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(payload.length, 20);
    central.writeUInt32LE(e.data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt16LE(0, 30);               // extra
    central.writeUInt16LE(0, 32);               // comment
    central.writeUInt16LE(0, 34);               // disk start
    central.writeUInt16LE(0, 36);               // internal attrs
    central.writeUInt32LE(((e.mode << 16) >>> 0), 38);  // external attrs = unix 权限（>>>0 防 32 位溢出）
    central.writeUInt32LE(offset, 42);

    centralParts.push(central, nameBuf);

    offset += local.length + nameBuf.length + payload.length;
}

const centralBuf = Buffer.concat(centralParts);
const localBuf = Buffer.concat(localParts);

const end = Buffer.alloc(22);
end.writeUInt32LE(0x06054b50, 0);
end.writeUInt16LE(0, 4);                      // disk
end.writeUInt16LE(0, 6);                      // disk with CD
end.writeUInt16LE(entries.length, 8);
end.writeUInt16LE(entries.length, 10);
end.writeUInt32LE(centralBuf.length, 12);
end.writeUInt32LE(localBuf.length, 16);
end.writeUInt16LE(0, 20);                     // comment len

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, Buffer.concat([localBuf, centralBuf, end]));

const execEntries = entries.filter((e) => e.mode === 0o100755);
console.log(`已生成：${outFile}`);
console.log(`  可执行（0755）：${execEntries.map((e) => e.name).join(', ') || '（没找到，见校验）'}`);
console.log(`  文件数：${entries.length}  体积：${(fs.statSync(outFile).size / 1024).toFixed(1)} KB`);
