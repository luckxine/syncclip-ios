// IPA 结构校验：不用 unzip，直接按 zip 规范解析，再钻到 Mach-O 的签名段里
// 确认 entitlement 真的签进去了。
//
//   node scripts/verify-ipa.js dist/SyncClipboard.ipa
//
// 为什么非要验 entitlement：整个方案唯一的命门就是「读剪贴板不弹提示」。
// 这件事只取决于二进制里有没有那几条 entitlement，而"我签名命令跑了"和
// "签名真的进去了"是两件事。这里把签发的包拆开、从 Mach-O 里把 entitlement
// 抠出来逐条对，验不过就不该上真机。

const fs = require('fs');
const zlib = require('zlib');

const file = process.argv[2];
if (!file) {
    console.error('用法：node scripts/verify-ipa.js <path/to.ipa>');
    process.exit(2);
}

const EXPECTED_BUNDLE_ID = 'com.cxk.syncclip';
const EXPECTED_URL_SCHEME = 'syncclip';
const REQUIRED_ENTITLEMENTS = [
    'com.apple.private.webkit.pasteboard',
    'com.apple.private.pasteboard.check-pasteboard',
    'com.apple.Pasteboard.background-access',
    'com.apple.Pasteboard.paste-unchecked',
];

let checks = 0;
const failures = [];

function check(cond, label, detail = '') {
    checks++;
    if (cond) {
        console.log(`  ✅ ${label}${detail ? '  ' + detail : ''}`);
    } else {
        console.log(`  ❌ ${label}${detail ? '  ' + detail : ''}`);
        failures.push(label);
    }
}

const buf = fs.readFileSync(file);
console.log(`\n检查 ${file}（${(buf.length / 1024).toFixed(1)} KB）\n`);

// ===========================================================================
// zip 解析
// ===========================================================================

console.log('[zip 外壳]');

// 从尾部往前找 EOCD
let eocd = -1;
for (let i = buf.length - 22; i >= 0 && i > buf.length - 66000; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
}
if (eocd < 0) {
    check(false, '找到 EOCD（zip 结束记录）');
    console.log('\n失败：不是一个合法 zip');
    process.exit(1);
}
check(true, '找到 EOCD');

const entryCount = buf.readUInt16LE(eocd + 10);
const cdSize = buf.readUInt32LE(eocd + 12);
const cdOffset = buf.readUInt32LE(eocd + 16);

check(cdOffset + cdSize <= buf.length, '中央目录偏移在文件范围内');

// 遍历中央目录
const entries = [];
let p = cdOffset;
for (let i = 0; i < entryCount; i++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) break;
    const method = buf.readUInt16LE(p + 10);
    const crc = buf.readUInt32LE(p + 16);
    const compSize = buf.readUInt32LE(p + 20);
    const uncompSize = buf.readUInt32LE(p + 24);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const externalAttrs = buf.readUInt32LE(p + 38);
    const localOffset = buf.readUInt32LE(p + 42);
    const name = buf.slice(p + 46, p + 46 + nameLen).toString('utf8');
    entries.push({ name, method, crc, compSize, uncompSize, externalAttrs, localOffset });
    p += 46 + nameLen + extraLen + commentLen;
}

check(entries.length === entryCount, `中央目录条目数一致（${entries.length}）`);

/// 取出某个条目的原始数据，并顺手校验 CRC（能验出写入器自己的 bug）
function readEntry(e) {
    if (buf.readUInt32LE(e.localOffset) !== 0x04034b50) throw new Error(`${e.name}: 本地头签名不对`);
    const nameLen = buf.readUInt16LE(e.localOffset + 26);
    const extraLen = buf.readUInt16LE(e.localOffset + 28);
    const start = e.localOffset + 30 + nameLen + extraLen;
    const raw = buf.slice(start, start + e.compSize);
    const data = e.method === 0 ? raw : zlib.inflateRawSync(raw);
    if (data.length !== e.uncompSize) throw new Error(`${e.name}: 解压后长度不符`);
    // CRC32
    const CRC_TABLE = readEntry.table || (readEntry.table = (() => {
        const t = new Int32Array(256);
        for (let n = 0; n < 256; n++) {
            let c = n;
            for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
            t[n] = c;
        }
        return t;
    })());
    let c = 0xffffffff;
    for (let i = 0; i < data.length; i++) c = CRC_TABLE[(c ^ data[i]) & 0xff] ^ (c >>> 8);
    if (((c ^ 0xffffffff) >>> 0) !== e.crc) throw new Error(`${e.name}: CRC 不符`);
    return data;
}

const byName = new Map(entries.map((e) => [e.name, e]));

// ---- 包结构 ----
console.log('\n[包结构]');

const appPrefixes = new Set();
for (const e of entries) {
    const m = e.name.match(/^Payload\/([^/]+\.app)\//);
    if (m) appPrefixes.add(m[1]);
}
check(appPrefixes.size === 1, 'Payload 下恰好一个 .app', [...appPrefixes].join(', '));

const appPrefix = [...appPrefixes][0];
const appName = appPrefix.replace(/\.app$/, '');
const infoEntry = byName.get(`Payload/${appPrefix}/Info.plist`);
const execEntry = byName.get(`Payload/${appPrefix}/${appName}`);

check(!!infoEntry, 'Info.plist 存在');
check(!!execEntry, `主可执行文件存在（${appName}）`);

// 数据完整性：把所有条目都读一遍
console.log('\n[数据完整性]');
let crcOK = true;
for (const e of entries) {
    try { readEntry(e); } catch (err) {
        crcOK = false;
        console.log(`  ❌ ${err.message}`);
        failures.push(`CRC/解压 ${e.name}`);
    }
}
if (crcOK) check(true, `全部 ${entries.length} 个条目 CRC 与长度校验通过`);

// ---- Info.plist ----
console.log('\n[Info.plist]');

let plist = '';
if (infoEntry) {
    plist = readEntry(infoEntry).toString('utf8');

    const str = (key) => {
        const m = plist.match(new RegExp(`<key>\\s*${key}\\s*</key>\\s*<string>([^<]*)</string>`));
        return m ? m[1] : null;
    };
    const arr = (key) => {
        const m = plist.match(new RegExp(`<key>\\s*${key}\\s*</key>\\s*<array>([\\s\\S]*?)</array>`));
        if (!m) return [];
        return [...m[1].matchAll(/<string>([^<]*)<\/string>/g)].map((x) => x[1]);
    };
    const has = (key) => new RegExp(`<key>\\s*${key}\\s*</key>`).test(plist);

    check(str('CFBundleIdentifier') === EXPECTED_BUNDLE_ID, 'CFBundleIdentifier 正确',
          str('CFBundleIdentifier'));
    check(str('CFBundleExecutable') === appName, 'CFBundleExecutable 与主二进制名一致',
          str('CFBundleExecutable'));
    check(!!execEntry, 'CFBundleExecutable 指向的条目存在');

    const minOS = parseFloat(str('MinimumOSVersion') || '0');
    check(minOS > 0 && minOS <= 15.5, 'MinimumOSVersion ≤ 15.5（用户是 15.5）', `= ${minOS}`);

    check(arr('UIBackgroundModes').includes('audio'),
          'UIBackgroundModes 含 audio（后台保活的前提）', arr('UIBackgroundModes').join(','));

    const urlTypes = plist.match(/CFBundleURLSchemes[\s\S]*?<\/array>/);
    const schemes = urlTypes ? [...urlTypes[0].matchAll(/<string>([^<]*)<\/string>/g)].map((x) => x[1]) : [];
    check(schemes.includes(EXPECTED_URL_SCHEME), 'URL scheme 正确（快捷指令/轻点背面用）',
          schemes.join(','));

    check(has('CFBundleIcons'), '声明了图标');
    check(str('CFBundleShortVersionString') !== null, '有版本号',
          str('CFBundleShortVersionString'));
}

// ---- 图标 ----
console.log('\n[图标]');

let iconChecked = 0;
for (const e of entries) {
    const m = e.name.match(/^(?:Payload\/[^/]+\/)(AppIcon60x60@(\d)x|AppIcon1024)\.png$/);
    if (!m) continue;
    iconChecked++;
    const data = readEntry(e);
    const isPNG = data.slice(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    const w = data.readUInt32BE(16), h = data.readUInt32BE(20);
    const expected = m[2] ? 60 * Number(m[2]) : 1024;
    check(isPNG && w === expected && h === expected,
          `${m[1]} 是 ${expected}×${expected} 的 PNG`, `实际 ${w}×${h}`);
}
check(iconChecked >= 2, `至少有两个尺寸的图标（实到 ${iconChecked} 个）`);

// ---- 可执行位 ----
console.log('\n[权限位]');
if (execEntry) {
    const mode = (execEntry.externalAttrs >>> 16) & 0xffff;
    check((mode & 0o777) === 0o755, '主二进制权限位 0755', `实际 0${mode.toString(8)}`);
}

// ---- Mach-O 与 entitlement（最关键的一项）----
console.log('\n[二进制与 entitlement]');

const LC_CODE_SIGNATURE = 0x1d;
const SUPERBLOB_MAGIC = 0xfade0cc0;
const ENTITLEMENTS_MAGIC = 0xfade7171;
const CSSLOT_ENTITLEMENTS = 5;

function extractEntitlements(data) {
    const magic = data.readUInt32LE(0);
    if (magic === 0xcafebabe || magic === 0xbebafeca) throw new Error('FAT 胖二进制，暂不支持');
    if (magic !== 0xfeedfacf) throw new Error(`不是 64 位 Mach-O（magic=0x${magic.toString(16)}）`);

    const cputype = data.readUInt32LE(4);
    const ncmds = data.readUInt32LE(16);
    let off = 32;
    let sigOff = 0, sigSize = 0;

    for (let i = 0; i < ncmds; i++) {
        if (off + 8 > data.length) break;
        const cmd = data.readUInt32LE(off);
        const cmdsize = data.readUInt32LE(off + 4);
        if (cmdsize < 8 || off + cmdsize > data.length) break;
        if (cmd === LC_CODE_SIGNATURE) {
            sigOff = data.readUInt32LE(off + 8);
            sigSize = data.readUInt32LE(off + 12);
        }
        off += cmdsize;
    }

    if (!sigOff || !sigSize) throw new Error('没有 LC_CODE_SIGNATURE：二进制没签名');
    if (sigOff + sigSize > data.length) throw new Error('签名段越界');

    if (data.readUInt32BE(sigOff) !== SUPERBLOB_MAGIC) {
        throw new Error(`SuperBlob magic 不对：0x${data.readUInt32BE(sigOff).toString(16)}`);
    }
    const count = data.readUInt32BE(sigOff + 8);
    let xml = null;
    for (let i = 0; i < count; i++) {
        const entry = sigOff + 12 + i * 8;
        const type = data.readUInt32BE(entry);
        const rel = data.readUInt32BE(entry + 4);
        if (type !== CSSLOT_ENTITLEMENTS) continue;
        const start = sigOff + rel;
        if (data.readUInt32BE(start) !== ENTITLEMENTS_MAGIC) {
            throw new Error('entitlement blob magic 不对');
        }
        const len = data.readUInt32BE(start + 4);
        xml = data.slice(start + 8, start + len).toString('utf8');
    }
    if (xml === null) throw new Error('签名里没有 entitlement 段');
    return { xml, cputype };
}

if (execEntry) {
    const bin = readEntry(execEntry);

    let ent = null;
    try {
        ent = extractEntitlements(bin);
        check(true, '从 Mach-O 签名段里读出了 entitlement');
    } catch (err) {
        check(false, '从 Mach-O 签名段里读出 entitlement', err.message);
    }

    if (ent) {
        check(ent.cputype === 0x0100000c, '架构是 arm64',
              ent.cputype === 0x0100000c ? 'arm64' : `0x${ent.cputype.toString(16)}`);

        for (const key of REQUIRED_ENTITLEMENTS) {
            check(ent.xml.includes(key), `entitlement: ${key}`);
        }
        // 这几个在 iOS 15/A12+ 上被禁，一签上去就崩，必须确认没被误加
        for (const banned of ['com.apple.private.cs.debugger', 'dynamic-codesigning',
                              'com.apple.private.skip-library-validation']) {
            check(!ent.xml.includes(banned), `没有误加被禁的 ${banned}`);
        }
    }
}

// ---- 汇总 ----
console.log('');
if (failures.length > 0) {
    console.error(`失败：${failures.length}/${checks} 项未通过`);
    failures.forEach((f) => console.error(`  - ${f}`));
    process.exit(1);
}
console.log(`全部通过（${checks} 项检查）`);
