// IPA 结构校验：不用 unzip，直接按 zip 规范解析，再钻到 Mach-O 的签名段里
// 确认 entitlement 真的签进去了。
//
//   node scripts/verify-ipa.js dist/SyncClipboard_1.0.0_arm64.ipa
//   node scripts/verify-ipa.js dist/PasteProbe_1.0.0_arm64.ipa --profile probe
//
// 两个档（profile）：
//   app    —— 剪贴板同步 App：四条剪贴板 entitlement + UIBackgroundModes=audio
//   probe  —— NE 探针：宿主 App + PlugIns 里的隧道 appex，两组 entitlement，
//             并额外验证 appex 的入口点真的是 _NSExtensionMain
//
// 为什么非要验 entitlement：整个方案唯一的命门就是「读剪贴板不弹提示」。
// 这件事只取决于二进制里有没有那几条 entitlement，而"我签名命令跑了"和
// "签名真的进去了"是两件事。这里把签发的包拆开、从 Mach-O 里把 entitlement
// 抠出来逐条对，验不过就不该上真机。

const fs = require('fs');
const zlib = require('zlib');

// ===========================================================================
// 档位定义
// ===========================================================================

const PASTEBOARD_ENTITLEMENTS = [
    'com.apple.private.webkit.pasteboard',
    'com.apple.private.pasteboard.check-pasteboard',
    'com.apple.Pasteboard.background-access',
    'com.apple.Pasteboard.paste-unchecked',
];

const BANNED_ENTITLEMENTS = [
    'com.apple.private.cs.debugger',
    'dynamic-codesigning',
    'com.apple.private.skip-library-validation',
];

const NE_ENTITLEMENTS = [
    'com.apple.developer.networking.networkextension',
    'com.apple.security.application-groups',
];

const PROFILES = {
    app: {
        label: '剪贴板同步 App',
        bundleId: 'com.cxk.syncclip',
        execName: 'SyncClipboard',
        maxMinOS: 15.5,
        urlScheme: 'syncclip',
        requireBackgroundModes: ['audio'],
        forbidBackgroundModes: false,
        requiredEntitlements: PASTEBOARD_ENTITLEMENTS,
        icons: true,
        appex: null,
    },
    probe: {
        label: 'NE 可行性探针',
        bundleId: 'com.cxk.pasteprobe',
        execName: 'PasteProbe',
        maxMinOS: 15.5,
        urlScheme: null,
        requireBackgroundModes: [],
        // 刻意的：探针要验「隧道是不是独立于 App 活着」，
        // 所以宿主 App 不能有任何后台保活，否则结论会被污染。
        forbidBackgroundModes: true,
        requiredEntitlements: PASTEBOARD_ENTITLEMENTS.concat(NE_ENTITLEMENTS),
        icons: true,
        appex: {
            dir: 'PlugIns/PasteProbeTunnel.appex',
            binName: 'PasteProbeTunnel',
            bundleId: 'com.cxk.pasteprobe.tunnel',
            packageType: 'XPC!',
            extensionPoint: 'com.apple.networkextension.packet-tunnel',
            principalClass: 'PasteProbeTunnel.ProbeTunnelProvider',
            requiredEntitlements: PASTEBOARD_ENTITLEMENTS.concat(NE_ENTITLEMENTS),
        },
    },
};

// ===========================================================================
// 参数
// ===========================================================================

const argv = process.argv.slice(2);
const file = argv.find((a) => !a.startsWith('--'));
const profileIdx = argv.indexOf('--profile');
const profileName = profileIdx >= 0 ? (argv[profileIdx + 1] || 'app') : 'app';
const profile = PROFILES[profileName];

if (!file) {
    console.error('用法：node scripts/verify-ipa.js <path/to.ipa> [--profile app|probe]');
    process.exit(2);
}
if (!profile) {
    console.error(`未知档位：${profileName}（可用：${Object.keys(PROFILES).join(', ')}）`);
    process.exit(2);
}

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
console.log(`\n检查 ${file}（${(buf.length / 1024).toFixed(1)} KB）  档位=${profileName}（${profile.label}）\n`);

// ===========================================================================
// zip 解析
// ===========================================================================

console.log('[zip 外壳]');

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

// ===========================================================================
// 包结构
// ===========================================================================

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

// ===========================================================================
// plist 小工具
// ===========================================================================

function makePlistTools(plist) {
    return {
        str(key) {
            const m = plist.match(new RegExp(`<key>\\s*${key}\\s*</key>\\s*<string>([^<]*)</string>`));
            return m ? m[1] : null;
        },
        arr(key) {
            const m = plist.match(new RegExp(`<key>\\s*${key}\\s*</key>\\s*<array>([\\s\\S]*?)</array>`));
            if (!m) return [];
            return [...m[1].matchAll(/<string>([^<]*)<\/string>/g)].map((x) => x[1]);
        },
        has(key) {
            return new RegExp(`<key>\\s*${key}\\s*</key>`).test(plist);
        },
    };
}

// ===========================================================================
// Info.plist
// ===========================================================================

console.log('\n[Info.plist]');

if (infoEntry) {
    const plist = readEntry(infoEntry).toString('utf8');
    const t = makePlistTools(plist);

    check(t.str('CFBundleIdentifier') === profile.bundleId, 'CFBundleIdentifier 正确',
          t.str('CFBundleIdentifier'));
    check(t.str('CFBundleExecutable') === appName, 'CFBundleExecutable 与主二进制名一致',
          t.str('CFBundleExecutable'));
    check(!!execEntry, 'CFBundleExecutable 指向的条目存在');

    const minOS = parseFloat(t.str('MinimumOSVersion') || '0');
    check(minOS > 0 && minOS <= profile.maxMinOS, `MinimumOSVersion ≤ ${profile.maxMinOS}`, `= ${minOS}`);

    const modes = t.arr('UIBackgroundModes');
    if (profile.forbidBackgroundModes) {
        check(modes.length === 0,
              '刻意没有声明任何 UIBackgroundModes（否则"隧道独立于 App 存活"的结论会被污染）',
              modes.join(',') || '（空）');
    } else {
        for (const mode of profile.requireBackgroundModes) {
            check(modes.includes(mode), `UIBackgroundModes 含 ${mode}`, modes.join(','));
        }
    }

    if (profile.urlScheme) {
        const urlTypes = plist.match(/CFBundleURLSchemes[\s\S]*?<\/array>/);
        const schemes = urlTypes ? [...urlTypes[0].matchAll(/<string>([^<]*)<\/string>/g)].map((x) => x[1]) : [];
        check(schemes.includes(profile.urlScheme), 'URL scheme 正确（快捷指令/轻点背面用）',
              schemes.join(','));
    }

    if (profile.icons) {
        check(t.has('CFBundleIcons'), '声明了图标');
    }
    check(t.str('CFBundleShortVersionString') !== null, '有版本号',
          t.str('CFBundleShortVersionString'));
}

// ===========================================================================
// 图标
// ===========================================================================

if (profile.icons) {
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
}

// ===========================================================================
// 权限位
// ===========================================================================

console.log('\n[权限位]');
function checkExecBit(entry, label) {
    if (!entry) return;
    const mode = (entry.externalAttrs >>> 16) & 0xffff;
    check((mode & 0o777) === 0o755, `${label} 权限位 0755`, `实际 0${mode.toString(8)}`);
}
checkExecBit(execEntry, '主二进制');

// ===========================================================================
// Mach-O 解析
// ===========================================================================

const LC_CODE_SIGNATURE = 0x1d;
const LC_SEGMENT_64 = 0x19;
const LC_SYMTAB = 0x2;
const LC_MAIN = 0x80000028;
const SUPERBLOB_MAGIC = 0xfade0cc0;
const ENTITLEMENTS_MAGIC = 0xfade7171;
const CSSLOT_ENTITLEMENTS = 5;

/// 把一份 Mach-O 拆成我们关心的几样东西：entitlement、架构、入口点符号。
function parseMachO(data) {
    const magic = data.readUInt32LE(0);
    if (magic === 0xcafebabe || magic === 0xbebafeca) throw new Error('FAT 胖二进制，暂不支持');
    if (magic !== 0xfeedfacf) throw new Error(`不是 64 位 Mach-O（magic=0x${magic.toString(16)}）`);

    const cputype = data.readUInt32LE(4);
    const ncmds = data.readUInt32LE(16);

    let off = 32;
    let sigOff = 0, sigSize = 0;
    let textVmaddr = null, textFileoff = null;
    let symoff = 0, nsyms = 0, stroff = 0, strsize = 0;
    let entryoff = null;

    for (let i = 0; i < ncmds; i++) {
        if (off + 8 > data.length) break;
        const cmd = data.readUInt32LE(off);
        const cmdsize = data.readUInt32LE(off + 4);
        if (cmdsize < 8 || off + cmdsize > data.length) break;

        if (cmd === LC_CODE_SIGNATURE) {
            sigOff = data.readUInt32LE(off + 8);
            sigSize = data.readUInt32LE(off + 12);
        } else if (cmd === LC_SEGMENT_64) {
            const segname = data.slice(off + 8, off + 24).toString('utf8').replace(/\0.*$/, '');
            if (segname === '__TEXT') {
                // segment_command_64 的字段顺序：cmd/cmdsize/segname(8+16)、
                // vmaddr(+24)、vmsize(+32)、fileoff(+40)、filesize(+48)。
                // fileoff 是 +40，别顺手写成 +32（那是 vmsize）。
                textVmaddr = data.readBigUInt64LE(off + 24);
                textFileoff = data.readBigUInt64LE(off + 40);
            }
        } else if (cmd === LC_SYMTAB) {
            symoff = data.readUInt32LE(off + 8);
            nsyms = data.readUInt32LE(off + 12);
            stroff = data.readUInt32LE(off + 16);
            strsize = data.readUInt32LE(off + 20);
        } else if (cmd === LC_MAIN) {
            entryoff = data.readBigUInt64LE(off + 8);
        }
        off += cmdsize;
    }

    // 签名段 → entitlement
    let xml = null;
    if (!sigOff || !sigSize) throw new Error('没有 LC_CODE_SIGNATURE：二进制没签名');
    if (sigOff + sigSize > data.length) throw new Error('签名段越界');
    if (data.readUInt32BE(sigOff) !== SUPERBLOB_MAGIC) {
        throw new Error(`SuperBlob magic 不对：0x${data.readUInt32BE(sigOff).toString(16)}`);
    }
    const count = data.readUInt32BE(sigOff + 8);
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

    // LC_MAIN 的 entryoff 是**文件偏移**，要换算成 vmaddr 才能去符号表里找名字。
    let entryName = null;
    const symCount = nsyms;
    if (entryoff !== null && textVmaddr !== null && nsyms) {
        const target = textVmaddr + (entryoff - textFileoff);
        for (let i = 0; i < nsyms; i++) {
            const o = symoff + i * 16;
            if (o + 16 > data.length) break;
            const strx = data.readUInt32LE(o);
            const value = data.readBigUInt64LE(o + 8);
            if (value !== target) continue;
            if (!strx) continue;
            const s = stroff + strx;
            if (s >= data.length) continue;
            const e = data.indexOf(0, s);
            entryName = data.slice(s, e === -1 ? undefined : e).toString('utf8');
            break;
        }
    }

    return { cputype, xml, entryoff, entryName, symCount };
}

function entitlementCheck(parsed, required, label) {
    if (!parsed) {
        check(false, `${label}：从 Mach-O 签名段里读出 entitlement`, '解析失败');
        return;
    }
    for (const key of required) {
        check(parsed.xml.includes(key), `${label} entitlement: ${key}`);
    }
    for (const banned of BANNED_ENTITLEMENTS) {
        check(!parsed.xml.includes(banned), `${label} 没有误加被禁的 ${banned}`);
    }
}

console.log('\n[主二进制与 entitlement]');

let appParsed = null;
if (execEntry) {
    const bin = readEntry(execEntry);
    try {
        appParsed = parseMachO(bin);
        check(true, '从 Mach-O 签名段里读出了 entitlement');
    } catch (err) {
        check(false, '从 Mach-O 签名段里读出 entitlement', err.message);
    }
    if (appParsed) {
        check(appParsed.cputype === 0x0100000c, '架构是 arm64',
              appParsed.cputype === 0x0100000c ? 'arm64' : `0x${appParsed.cputype.toString(16)}`);
        entitlementCheck(appParsed, profile.requiredEntitlements, 'App');
    }
}

// ===========================================================================
// appex（probe 档）
// ===========================================================================

if (profile.appex) {
    const spec = profile.appex;
    const appexPrefix = `Payload/${appPrefix}/${spec.dir}/`;

    console.log('\n[appex（PlugIns）]');

    check(entries.some((e) => e.name.startsWith(appexPrefix)), `appex 目录存在（${spec.dir}）`);

    const appexInfoEntry = byName.get(`${appexPrefix}Info.plist`);
    const appexBinEntry = byName.get(`${appexPrefix}${spec.binName}`);

    check(!!appexInfoEntry, 'appex 的 Info.plist 存在');
    check(!!appexBinEntry, `appex 可执行文件存在（${spec.binName}）`);

    if (appexInfoEntry) {
        const plist = readEntry(appexInfoEntry).toString('utf8');
        const t = makePlistTools(plist);

        check(t.str('CFBundleIdentifier') === spec.bundleId, 'appex CFBundleIdentifier 正确',
              t.str('CFBundleIdentifier'));
        check(t.str('CFBundleExecutable') === spec.binName, 'appex CFBundleExecutable 正确',
              t.str('CFBundleExecutable'));
        check(t.str('CFBundlePackageType') === spec.packageType,
              `appex CFBundlePackageType = ${spec.packageType}`, t.str('CFBundlePackageType'));
        check(t.str('NSExtensionPointIdentifier') === spec.extensionPoint,
              `NSExtensionPointIdentifier = ${spec.extensionPoint}`,
              t.str('NSExtensionPointIdentifier'));
        check(t.str('NSExtensionPrincipalClass') === spec.principalClass,
              `NSExtensionPrincipalClass = ${spec.principalClass}`, t.str('NSExtensionPrincipalClass'));

        const minOS = parseFloat(t.str('MinimumOSVersion') || '0');
        check(minOS > 0 && minOS <= profile.maxMinOS, `appex MinimumOSVersion ≤ ${profile.maxMinOS}`,
              `= ${minOS}`);
    }

    checkExecBit(appexBinEntry, 'appex 二进制');

    if (appexBinEntry) {
        try {
            const parsed = parseMachO(readEntry(appexBinEntry));
            entitlementCheck(parsed, spec.requiredEntitlements, 'appex');

            // 入口点：SwiftPM 没有 app-extension 产品类型，入口点靠链接器的
            // -e _NSExtensionMain。它没生效的话 appex 会「静默什么都不做」，
            // 现象和 entitlement 没生效一样，所以这一条必须验。
            if (!parsed.symCount) {
                check(false, 'appex 入口点是 _NSExtensionMain',
                      '符号表是空的，验不了（不要用 strip 构建）');
            } else if (parsed.entryName === null) {
                check(false, 'appex 入口点是 _NSExtensionMain',
                      'LC_MAIN 指向的地址在符号表里找不到对应符号');
            } else {
                check(parsed.entryName.replace(/^_+/, '').startsWith('NSExtensionMain'),
                      'appex 入口点是 _NSExtensionMain', `实际：${parsed.entryName}`);
            }
        } catch (err) {
            check(false, 'appex 二进制解析', err.message);
        }
    }
}

// ===========================================================================
// 汇总
// ===========================================================================

console.log('');
if (failures.length > 0) {
    console.error(`失败：${failures.length}/${checks} 项未通过`);
    failures.forEach((f) => console.error(`  - ${f}`));
    process.exit(1);
}
console.log(`全部通过（${checks} 项检查）`);
