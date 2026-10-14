// 打包/验包流水线的自测。
//
//   node scripts/selftest-pipeline.js
//
// 为什么需要它：verify-ipa.js 里最关键的一项是「从 Mach-O 签名段里把
// entitlement 抠出来对一遍」。如果这个解析器本身写错了，它会对任何包都报错；
// 更糟的是如果它写得"太宽容"，它会永远报通过 —— 那这个校验就等于没有。
//
// 所以这里造一个**带真实签名段结构**的合成 Mach-O（SuperBlob + entitlements
// blob，字节序和偏移都按规范来），先确认正例能过，再逐个注入缺陷确认能报出来。
// 只有正例过 + 反例不过，这个校验才算可信。
//
// 顺带把 shell 脚本也扫一遍：开发机是 Windows，脚本若被 checkout 成 CRLF，
// macOS runner 上会直接 "bad interpreter: /bin/bash^M"。这类问题在 CI 上
// 表现为莫名其妙的失败，在这里几毫秒就能抳住。

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const WORK = path.join(ROOT, '.selftest');

/// 在 .app 里生成图标时用；不要和下面跑子进程的 run() 混淆
function runSync(cmd, args, opts) {
    return execFileSync(cmd, args, opts);
}

// ===========================================================================
// 造一个带 code signature 段的 Mach-O
// ===========================================================================

const LC_CODE_SIGNATURE = 0x1d;
const LC_SEGMENT_64 = 0x19;
const LC_SYMTAB = 0x2;
const LC_MAIN = 0x80000028;
const SUPERBLOB_MAGIC = 0xfade0cc0;
const ENTITLEMENTS_MAGIC = 0xfade7171;

// 除了签名，还得造出 __TEXT 段、符号表和 LC_MAIN：verify-ipa.js 里有一条检查是
// 「appex 的 LC_MAIN 指向的符号是不是 _NSExtensionMain」，合成二进制里没有这些结构
// 的话，那条检查就永远只会「因为找不到符号而失败」，验不出它会不会误判。
//
// opts: cputype / entrySymbol（默认 _NSExtensionMain）/ withMain（false=不写 LC_MAIN）
function buildMachO(entitlementsXml, opts = {}) {
    const cputype = opts.cputype === undefined ? 0x0100000c : opts.cputype;
    const withMain = opts.withMain !== false;
    const entrySymbol = opts.entrySymbol === undefined ? '_NSExtensionMain' : opts.entrySymbol;
    const signed = entitlementsXml !== '';

    const xml = Buffer.from(entitlementsXml, 'utf8');
    const entBlobLen = 8 + xml.length;
    const superLen = 12 + 8 + entBlobLen;

    const headerSize = 32;
    const segCmdSize = 72;
    const symtabCmdSize = 24;
    const mainCmdSize = withMain ? 24 : 0;
    const sigCmdSize = signed ? 16 : 0;
    const ncmds = 3 + (withMain ? 1 : 0) + (signed ? 1 : 0);
    const cmdsSize = segCmdSize + symtabCmdSize + mainCmdSize + sigCmdSize;

    const codeOff = headerSize + cmdsSize;
    const symOff = codeOff + 16;

    const symbols = entrySymbol ? [entrySymbol] : [];
    const strOff = symOff + symbols.length * 16;
    let strTab = Buffer.from([0]);
    const strIndexes = [];
    for (const name of symbols) {
        strIndexes.push(strTab.length);
        strTab = Buffer.concat([strTab, Buffer.from(name + '\0', 'utf8')]);
    }

    const sigOff = strOff + strTab.length;
    const total = signed ? sigOff + superLen : sigOff;
    const out = Buffer.alloc(total);
    const TEXT_VMADDR = 0x100000000n;

    // mach_header_64
    out.writeUInt32LE(0xfeedfacf, 0);
    out.writeUInt32LE(cputype, 4);
    out.writeUInt32LE(0, 8);
    out.writeUInt32LE(2, 12);              // MH_EXECUTE
    out.writeUInt32LE(ncmds, 16);
    out.writeUInt32LE(cmdsSize, 20);
    out.writeUInt32LE(0, 24);
    out.writeUInt32LE(0, 28);

    let off = headerSize;

    // LC_SEGMENT_64 __TEXT（vmaddr 0x100000000、fileoff 0，entryoff 才能换算成 vmaddr）
    out.writeUInt32LE(LC_SEGMENT_64, off);
    out.writeUInt32LE(segCmdSize, off + 4);
    out.write('__TEXT\0\0\0\0\0\0\0\0\0\0', off + 8, 16, 'utf8');
    out.writeBigUInt64LE(TEXT_VMADDR, off + 24);
    out.writeBigUInt64LE(BigInt(total), off + 32);
    out.writeBigUInt64LE(0n, off + 40);
    out.writeBigUInt64LE(BigInt(total), off + 48);
    out.writeUInt32LE(5, off + 56);
    out.writeUInt32LE(5, off + 60);
    out.writeUInt32LE(0, off + 64);
    out.writeUInt32LE(0, off + 68);
    off += segCmdSize;

    // LC_SYMTAB
    out.writeUInt32LE(LC_SYMTAB, off);
    out.writeUInt32LE(symtabCmdSize, off + 4);
    out.writeUInt32LE(symOff, off + 8);
    out.writeUInt32LE(symbols.length, off + 12);
    out.writeUInt32LE(strOff, off + 16);
    out.writeUInt32LE(strTab.length, off + 20);
    off += symtabCmdSize;

    // LC_MAIN（entryoff 是文件偏移，不是 vmaddr）
    if (withMain) {
        out.writeUInt32LE(LC_MAIN, off);
        out.writeUInt32LE(mainCmdSize, off + 4);
        out.writeBigUInt64LE(BigInt(codeOff), off + 8);
        out.writeBigUInt64LE(0n, off + 16);
        off += mainCmdSize;
    }

    // LC_CODE_SIGNATURE
    if (signed) {
        out.writeUInt32LE(LC_CODE_SIGNATURE, off);
        out.writeUInt32LE(sigCmdSize, off + 4);
        out.writeUInt32LE(sigOff, off + 8);
        out.writeUInt32LE(superLen, off + 12);
    }

    // 符号表：入口符号的地址就是 __TEXT.vmaddr + codeOff
    symbols.forEach((name, i) => {
        const o = symOff + i * 16;
        out.writeUInt32LE(strIndexes[i], o);
        out.writeUInt8(0x0f, o + 4);                     // N_SECT | N_EXT
        out.writeUInt8(1, o + 5);                        // n_sect
        out.writeUInt16LE(0, o + 6);
        out.writeBigUInt64LE(TEXT_VMADDR + BigInt(codeOff), o + 8);
    });
    strTab.copy(out, strOff);

    // SuperBlob（代码签名里的结构一律大端）
    if (signed) {
        out.writeUInt32BE(SUPERBLOB_MAGIC, sigOff);
        out.writeUInt32BE(superLen, sigOff + 4);
        out.writeUInt32BE(1, sigOff + 8);
        out.writeUInt32BE(5, sigOff + 12);               // CSSLOT_ENTITLEMENTS
        out.writeUInt32BE(20, sigOff + 16);

        const b = sigOff + 20;
        out.writeUInt32BE(ENTITLEMENTS_MAGIC, b);
        out.writeUInt32BE(entBlobLen, b + 4);
        xml.copy(out, b + 8);
    }

    return out;
}

// ===========================================================================
// 造 Info.plist
// ===========================================================================

function buildInfoPlist(overrides = {}) {
    const o = {
        bundleId: 'com.cxk.syncclip',
        executable: 'SyncClipboard',
        minOS: '15.0',
        backgroundModes: ['audio'],
        urlScheme: 'syncclip',
        withIcons: true,
        ...overrides,
    };
    return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>${o.bundleId}</string>
	<key>CFBundleExecutable</key><string>${o.executable}</string>
	<key>CFBundleName</key><string>SyncClipboard</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>MinimumOSVersion</key><string>${o.minOS}</string>
${o.backgroundModes.length ? `	<key>UIBackgroundModes</key>
	<array>
${o.backgroundModes.map((m) => `		<string>${m}</string>`).join('\n')}
	</array>
` : ''}${o.urlScheme ? `	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLSchemes</key>
			<array><string>${o.urlScheme}</string></array>
		</dict>
	</array>
` : ''}${o.withIcons ? `	<key>CFBundleIcons</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array><string>AppIcon60x60</string></array>
		</dict>
	</dict>
` : ''}</dict>
</plist>
`;
}

const ENTITLEMENTS_XML = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.private.webkit.pasteboard</key><true/>
	<key>com.apple.private.pasteboard.check-pasteboard</key><true/>
	<key>com.apple.Pasteboard.background-access</key><true/>
	<key>com.apple.Pasteboard.paste-unchecked</key><true/>
</dict>
</plist>
`;

// ===========================================================================
// 造一个 .app 目录
// ===========================================================================

function buildApp(dir, opts = {}) {
    const o = {
        entitlementsXml: ENTITLEMENTS_XML,
        infoOverrides: {},
        iconMismatch: false,   // true = 故意把 120×120 的图装进 @3x 文件名
        execMode: 0o755,
        omitIcons: false,
        ...opts,
    };

    fs.rmSync(dir, { recursive: true, force: true });
    fs.mkdirSync(dir, { recursive: true });

    const execName = 'SyncClipboard';
    const bin = buildMachO(o.entitlementsXml, o.macho || {});
    fs.writeFileSync(path.join(dir, execName), bin);
    fs.chmodSync(path.join(dir, execName), o.execMode);

    fs.writeFileSync(path.join(dir, 'Info.plist'), buildInfoPlist(o.infoOverrides));

    if (!o.omitIcons) {
        // 直接用小图标生成器产出真 PNG，靠改尺寸来制造"文件名与分辨率不符"
        const tmp = path.join(WORK, 'icons');
        runSync('node', [path.join(__dirname, 'make-icons.js'), tmp], { cwd: ROOT, stdio: 'pipe' });
        fs.copyFileSync(path.join(tmp, 'AppIcon60x60@2x.png'), path.join(dir, 'AppIcon60x60@2x.png'));
        // 正常应该拷 @3x（180×180）；iconMismatch 时故意拷 @2x（120×120）制造文件名与分辨率不符
        const src = o.iconMismatch ? 'AppIcon60x60@2x.png' : 'AppIcon60x60@3x.png';
        fs.copyFileSync(path.join(tmp, src), path.join(dir, 'AppIcon60x60@3x.png'));
    }

    return dir;
}

// ===========================================================================
// 探针档：宿主 App + PlugIns 里的 appex
// ===========================================================================

function probeEntitlementsXml(suffix, extra = '') {
    return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>application-identifier</key><string>TROLLTROLL.com.cxk.pasteprobe${suffix}</string>
\t<key>com.apple.developer.team-identifier</key><string>TROLLTROLL</string>
\t<key>com.apple.developer.networking.networkextension</key>
\t<array><string>packet-tunnel-provider</string></array>
\t<key>com.apple.security.application-groups</key>
\t<array><string>group.com.cxk.pasteprobe</string></array>
\t<key>com.apple.private.webkit.pasteboard</key><true/>
\t<key>com.apple.private.pasteboard.check-pasteboard</key><true/>
\t<key>com.apple.Pasteboard.background-access</key><true/>
\t<key>com.apple.Pasteboard.paste-unchecked</key><true/>
${extra}</dict>
</plist>
`;
}

const PROBE_APP_ENT = probeEntitlementsXml('');
const PROBE_APPEX_ENT = probeEntitlementsXml('.tunnel');

function buildProbeAppPlist(backgroundModes) {
    return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleIdentifier</key><string>com.cxk.pasteprobe</string>
\t<key>CFBundleExecutable</key><string>PasteProbe</string>
\t<key>CFBundleName</key><string>PasteProbe</string>
\t<key>CFBundleShortVersionString</key><string>1.0.0</string>
\t<key>CFBundleVersion</key><string>1</string>
\t<key>CFBundlePackageType</key><string>APPL</string>
\t<key>MinimumOSVersion</key><string>15.0</string>
${backgroundModes.length ? `\t<key>UIBackgroundModes</key>\n\t<array>\n${backgroundModes.map((m) => `\t\t<string>${m}</string>`).join('\n')}\n\t</array>\n` : ''}\t<key>CFBundleIcons</key>
\t<dict>
\t\t<key>CFBundlePrimaryIcon</key>
\t\t<dict>
\t\t\t<key>CFBundleIconFiles</key>
\t\t\t<array><string>AppIcon60x60</string></array>
\t\t</dict>
\t</dict>
</dict>
</plist>
`;
}

function buildAppexPlist(overrides = {}) {
    const o = {
        bundleId: 'com.cxk.pasteprobe.tunnel',
        executable: 'PasteProbeTunnel',
        packageType: 'XPC!',
        extensionPoint: 'com.apple.networkextension.packet-tunnel',
        principalClass: 'PasteProbeTunnel.ProbeTunnelProvider',
        minOS: '15.0',
        ...overrides,
    };
    return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleIdentifier</key><string>${o.bundleId}</string>
\t<key>CFBundleExecutable</key><string>${o.executable}</string>
\t<key>CFBundlePackageType</key><string>${o.packageType}</string>
\t<key>CFBundleShortVersionString</key><string>1.0.0</string>
\t<key>CFBundleVersion</key><string>1</string>
\t<key>MinimumOSVersion</key><string>${o.minOS}</string>
\t<key>NSExtension</key>
\t<dict>
\t\t<key>NSExtensionPointIdentifier</key><string>${o.extensionPoint}</string>
\t\t<key>NSExtensionPrincipalClass</key><string>${o.principalClass}</string>
\t</dict>
</dict>
</plist>
`;
}

function buildProbeApp(dir, opts = {}) {
    const o = {
        appEntitlementsXml: PROBE_APP_ENT,
        appexEntitlementsXml: PROBE_APPEX_ENT,
        appMacho: {},
        appexMacho: {},
        appexInfoOverrides: {},
        backgroundModes: [],
        omitAppex: false,
        appexExecMode: 0o755,
        ...opts,
    };

    fs.rmSync(dir, { recursive: true, force: true });
    fs.mkdirSync(dir, { recursive: true });

    fs.writeFileSync(path.join(dir, 'PasteProbe'), buildMachO(o.appEntitlementsXml, o.appMacho));
    fs.chmodSync(path.join(dir, 'PasteProbe'), 0o755);
    fs.writeFileSync(path.join(dir, 'Info.plist'), buildProbeAppPlist(o.backgroundModes));

    const tmp = path.join(WORK, 'icons');
    runSync('node', [path.join(__dirname, 'make-icons.js'), tmp], { cwd: ROOT, stdio: 'pipe' });
    fs.copyFileSync(path.join(tmp, 'AppIcon60x60@2x.png'), path.join(dir, 'AppIcon60x60@2x.png'));
    fs.copyFileSync(path.join(tmp, 'AppIcon60x60@3x.png'), path.join(dir, 'AppIcon60x60@3x.png'));

    if (o.omitAppex) return dir;

    const appexDir = path.join(dir, 'PlugIns/PasteProbeTunnel.appex');
    fs.mkdirSync(appexDir, { recursive: true });
    const bin = path.join(appexDir, 'PasteProbeTunnel');
    fs.writeFileSync(bin, buildMachO(o.appexEntitlementsXml, o.appexMacho));
    fs.chmodSync(bin, o.appexExecMode);
    fs.writeFileSync(path.join(appexDir, 'Info.plist'), buildAppexPlist(o.appexInfoOverrides));
    return dir;
}

// ===========================================================================
// 跑流水线
// ===========================================================================

function run(script, args) {
    const r = require('child_process').spawnSync('node', [path.join(__dirname, script), ...args],
                                               { cwd: ROOT, encoding: 'utf8' });
    return { ok: r.status === 0, out: (r.stdout || '') + (r.stderr || '') };
}

function pipeline(appDir, ipaPath, profile = 'app', appName = 'SyncClipboard') {
    const pack = run('make-ipa.js', [appName, appDir, ipaPath]);
    if (!pack.ok) return { ok: false, stage: 'make-ipa', out: pack.out };
    const verify = run('verify-ipa.js', [ipaPath, '--profile', profile]);
    return { ok: verify.ok, stage: 'verify-ipa', out: verify.out };
}

function probePipeline(opts) {
    const appDir = buildProbeApp(path.join(WORK, 'probe.app'), opts);
    const ipa = path.join(WORK, 'probe.ipa');
    return Object.assign(pipeline(appDir, ipa, 'probe', 'PasteProbe'), { appDir, ipa });
}

function expectProbePass(label, opts) {
    const r = probePipeline(opts);
    if (r.ok) {
        console.log(`  ✅ ${label}：如预期通过`);
    } else {
        failures++;
        console.log(`  ❌ ${label}：本该通过却失败了（stage=${r.stage}）`);
        console.log(r.out.split('\n').filter((l) => l.includes('❌')).map((l) => '       ' + l.trim()).join('\n'));
    }
}

function expectProbeFail(label, opts, expectMention) {
    const r = probePipeline(opts);
    if (!r.ok) {
        if (!expectMention || r.out.includes(expectMention)) {
            console.log(`  ✅ ${label}：被正确拦下`);
        } else {
            failures++;
            console.log(`  ❌ ${label}：确实失败了，但不是因为预期的那一项（想看到 "${expectMention}"）`);
            console.log(r.out.split('\n').filter((l) => l.includes('❌')).map((l) => '       ' + l.trim()).join('\n'));
        }
    } else {
        failures++;
        console.log(`  ❌ ${label}：本该失败却通过了 —— 校验器太宽松，等于没验`);
    }
}

// ===========================================================================
// shell 脚本体检：CRLF、shebang、可执行位（用 git 的 index 而不是工作区，
// 因为 CI 上 checkout 出来的才是真正要跑的东西）
// ===========================================================================

function checkShellScripts() {
    console.log('[shell 脚本]');
    let bad = 0;

    const tracked = execFileSync('git', ['ls-files', '*.sh'], { cwd: ROOT, encoding: 'utf8' })
        .split('\n').filter(Boolean);

    if (tracked.length === 0) {
        console.log('  ⚠️  git ls-files 没列出 *.sh（不在 git 仓库里？）');
        return 0;
    }

    for (const f of tracked) {
        // git cat-file 给出的才是真正会被 checkout 的字节
        const content = execFileSync('git', ['cat-file', 'blob', `HEAD:${f}`],
                                     { cwd: ROOT, maxBuffer: 16 * 1024 * 1024 });

        const hasCR = content.includes(0x0d);
        if (hasCR) {
            console.log(`  ❌ ${f}：含 CR 字节。macOS 上会 bad interpreter，检查 .gitattributes`);
            bad++;
        }

        const firstLine = content.slice(0, content.indexOf(0x0a)).toString('utf8');
        if (!firstLine.startsWith('#!')) {
            console.log(`  ❌ ${f}：缺少 shebang`);
            bad++;
        } else if (!firstLine.includes('/bin/bash') && !firstLine.includes('/bin/sh')) {
            console.log(`  ⚠️  ${f}：shebang 是 ${firstLine}`);
        }

        // $VAR 后面紧跟非 ASCII 字符（中文全角括号、顿号等）时，bash 会把那个字节
        // 当成变量名的一部分 —— 报的是 "TUNNEL_ENT?: unbound variable"，
        // 错误信息里变量名带一个替换字符，很难看出问题是标点。
        // 这个坑只在「中文 echo 里直接跟变量」时出现，而且只在真跑脚本时才炸，
        // 本地看几遍都看不出来。所以在这里抓。
        const lines = content.toString('utf8').split('\n');
        for (let i = 0; i < lines.length; i++) {
            const m = lines[i].match(/\$[A-Za-z_][A-Za-z0-9_]*[\u0080-\uffff]/);
            if (m) {
                const name = m[0].slice(1, -1);
                console.log(`  ❌ ${f}:${i + 1}：变量 ${name} 后面紧跟非 ASCII 字符`);
                console.log(`       写成美元符加大括号：\${${name}}`);
                bad++;
            }
        }
    }

    if (bad === 0) console.log(`  ✅ ${tracked.length} 个脚本：换行符与 shebang 都正常`);
    return bad;
}

// ===========================================================================
// SigV4 自检基线的独立校验
//
// App 里有一个运行时自检：拿 AWS 官方测试向量跑一遍签名密钥派生，对不上就在诊断页报错。
// 但那个自检本身依赖写在 SCSigV4.swift 里的“期望值”。如果写错了，
// 自检会反过来把正确的实现判成错的（或者更糟：把一个错实现判成对的）。
//
// 所以这里用 node 的 crypto 独立算一遍，确认写在 Swift 里的测试向量确实正确。
// 这样「CI 验向量 → 向量验 Swift 实现」就成了一条完整的链。
// ===========================================================================

function checkSigV4Vector() {
    console.log('[SigV4 自检基线]');
    const src = fs.readFileSync(
        path.join(ROOT, 'Sources/SyncClipCore/SCSigV4.swift'), 'utf8');

    // 从 Swift 源码里把自检用的输入和期望值抓出来，而不是在这里重抄一遍
    const secret = src.match(/secretAccessKey:\s*"([^"]+)"/);
    const dateStamp = src.match(/dateStamp:\s*"(\d{8})"/);
    const region = src.match(/region:\s*"([a-z0-9-]+)"/);
    const service = src.match(/service:\s*"([a-z0-9]+)"\s*\)/);
    const expected = src.match(/let expected = "([0-9a-f]{64})"/);

    const problems = [];
    if (!secret) problems.push('抓不到 secretAccessKey');
    if (!dateStamp) problems.push('抓不到 dateStamp');
    if (!region) problems.push('抓不到 region');
    if (!service) problems.push('抓不到 service');
    if (!expected) problems.push('抓不到 expected 签名密钥');

    if (problems.length) {
        problems.forEach((p) => console.log(`  ❌ ${p}`));
        return problems.length;
    }

    const crypto = require('crypto');
    const hmac = (key, data) => crypto.createHmac('sha256', key).update(data, 'utf8').digest();

    const kDate = hmac('AWS4' + secret[1], dateStamp[1]);
    const kRegion = hmac(kDate, region[1]);
    const kService = hmac(kRegion, service[1]);
    const kSigning = hmac(kService, 'aws4_request').toString('hex');

    if (kSigning !== expected[1]) {
        console.log(`  ❌ SCSigV4.swift 里的期望值不对`);
        console.log(`     源码写的：${expected[1]}`);
        console.log(`     实际应为：${kSigning}`);
        return 1;
    }

    console.log(`  ✅ 测试向量与 node crypto 独立算出的结果一致`);
    console.log(`     ${service[1]} / ${region[1]} / ${dateStamp[1]} → ${kSigning.slice(0, 16)}…`);

    // 顺带确认 SCSigV4 里那几条 uriEncode 断言的字面量也没写错
    const uriCases = [
        ['file/a b+c~d.txt', false, 'file/a%20b%2Bc~d.txt'],
        ['a/b', true, 'a%2Fb'],
    ];
    let uriBad = 0;
    for (const [input, encodeSlash, want] of uriCases) {
        if (!src.includes(`"${want}"`)) {
            console.log(`  ❌ SCSigV4.swift 自检里找不到期望值 "${want}"（输入 ${input}）`);
            uriBad++;
        }
    }
    if (uriBad === 0) console.log('  ✅ uriEncode 自检断言的字面量齐备');

    return uriBad;
}

// ===========================================================================
// main
// ===========================================================================

fs.rmSync(WORK, { recursive: true, force: true });
fs.mkdirSync(WORK, { recursive: true });

let failures = 0;

function expectPass(label, opts) {
    const appDir = buildApp(path.join(WORK, 'pass.app'), opts);
    const ipa = path.join(WORK, 'pass.ipa');
    const r = pipeline(appDir, ipa);
    if (r.ok) {
        console.log(`  ✅ ${label}：如预期通过`);
    } else {
        failures++;
        console.log(`  ❌ ${label}：本该通过却失败了（stage=${r.stage}）`);
        console.log(r.out.split('\n').filter((l) => l.includes('❌')).map((l) => '       ' + l.trim()).join('\n'));
    }
}

function expectFail(label, opts, expectMention) {
    const appDir = buildApp(path.join(WORK, 'fail.app'), opts);
    const ipa = path.join(WORK, 'fail.ipa');
    const r = pipeline(appDir, ipa);
    if (!r.ok) {
        const hit = !expectMention || r.out.includes(expectMention);
        if (hit) {
            console.log(`  ✅ ${label}：被正确拦下`);
        } else {
            failures++;
            console.log(`  ❌ ${label}：确实失败了，但不是因为预期的那一项（想看到 "${expectMention}"）`);
            console.log(r.out.split('\n').filter((l) => l.includes('❌')).map((l) => '       ' + l.trim()).join('\n'));
        }
    } else {
        failures++;
        console.log(`  ❌ ${label}：本该失败却通过了 —— 校验器太宽松，等于没验`);
    }
}

console.log('正例（应当通过）');

failures += checkShellScripts();
failures += checkSigV4Vector();
console.log('');

expectPass('完整的包', {});

console.log('\n反例（应当被拦下）');

// 少一条 entitlement —— 这是整个方案最要命的一项
expectFail('剪贴板 entitlement 少一条',
    { entitlementsXml: ENTITLEMENTS_XML.replace(/\s*<key>com\.apple\.Pasteboard\.background-access<\/key><true\/>/, '') },
    'background-access');

// 误签了 iOS 15/A12+ 上被禁的 entitlement（一签就崩）
expectFail('误加被禁的 skip-library-validation',
    { entitlementsXml: ENTITLEMENTS_XML.replace(
        '<key>com.apple.private.webkit.pasteboard</key><true/>',
        '<key>com.apple.private.webkit.pasteboard</key><true/>\n\t<key>com.apple.private.skip-library-validation</key><true/>') },
    'skip-library-validation');

// 二进制根本没签名
expectFail('二进制没有签名段',
    { entitlementsXml: '' },
    'entitlement');

// 少了后台 audio 声明 —— 保活的前提
expectFail('Info.plist 缺 UIBackgroundModes=audio',
    { infoOverrides: { backgroundModes: [] } },
    'audio');

// bundle id 写错
expectFail('Bundle ID 不对',
    { infoOverrides: { bundleId: 'com.example.wrong' } },
    'CFBundleIdentifier');

// 部署目标高于用户系统
expectFail('MinimumOSVersion 高于 15.5',
    { infoOverrides: { minOS: '16.0' } },
    'MinimumOSVersion');

// 图标文件名与分辨率不符（@3x 里装 120×120 的图）
expectFail('图标分辨率与文件名不符',
    { iconMismatch: true },
    'PNG');

// 源文件没有可执行位时，打包器应该把它归一化成 0755。
// 这是必须的：Windows 上 chmod 根本设不了执行位，而 git 也不可靠地记录它，
// 所以不能依赖源文件的权限位。
expectPass('源文件权限是 0644 → 打包器归一化为 0755', { execMode: 0o644 });

// 少 URL scheme
expectFail('URL scheme 缺失',
    { infoOverrides: { urlScheme: '' } },
    'URL scheme');

console.log('\n探针档（NE 探针：宿主 App + PlugIns 里的 appex）');

expectProbePass('完整的探针包（含 appex 入口点检查）', {});

// 打包器必须接照每个 Info.plist 里的 CFBundleExecutable 给可执行位。
// 只看顶层 Info.plist 的话 appex 二进制会拿到 0644，装上去 PluginKit 起不来。
expectProbePass('appex 源文件权限 0644 → 打包器归一化为 0755', { appexExecMode: 0o644 });

// 入口点没接上（链接器的 -e 没生效）—— appex 会「静默什么都不做」
expectProbeFail('appex 入口点不是 _NSExtensionMain',
    { appexMacho: { entrySymbol: '_main' } }, '实际：_main');

// appex 缺网络扩展 entitlement —— 隧道建不起来
expectProbeFail('appex 缺 networkextension entitlement',
    { appexEntitlementsXml: PROBE_APPEX_ENT.replace(
        /<key>com\.apple\.developer\.networking\.networkextension<\/key>\s*<array><string>packet-tunnel-provider<\/string><\/array>/, '') },
    'appex entitlement: com.apple.developer.networking.networkextension');

// appex 的 NSExtension 段写错 —— NSExtensionMain 找不到主类
expectProbeFail('appex 的 NSExtensionPointIdentifier 写错',
    { appexInfoOverrides: { extensionPoint: 'com.apple.networkextension.dns-proxy' } },
    'NSExtensionPointIdentifier');
expectProbeFail('appex 的 NSExtensionPrincipalClass 写错',
    { appexInfoOverrides: { principalClass: 'Wrong.Module.Class' } },
    'NSExtensionPrincipalClass');
expectProbeFail('appex 的 CFBundlePackageType 不是 XPC!',
    { appexInfoOverrides: { packageType: 'APPL' } }, 'CFBundlePackageType');

// appex 压根没打进包里
expectProbeFail('appex 目录整个缺失', { omitAppex: true }, 'appex 目录存在');

// 探针 App 不能有任何后台模式（否则「隧道独立于 App 存活」的结论会被污染）
expectProbeFail('探针 App 混进了 UIBackgroundModes',
    { backgroundModes: ['audio'] }, 'UIBackgroundModes');

// 宿主 App 与 appex 共享容器靠的就是这一条
expectProbeFail('宿主 App 缺 application-groups',
    { appEntitlementsXml: PROBE_APP_ENT.replace(
        /<key>com\.apple\.security\.application-groups<\/key>\s*<array><string>group\.com\.cxk\.pasteprobe<\/string><\/array>/, '') },
    'entitlement: com.apple.security.application-groups');

if (!process.env.SELFTEST_KEEP) fs.rmSync(WORK, { recursive: true, force: true });

console.log('');
if (failures > 0) {
    console.error(`${failures} 项不符合预期`);
    process.exit(1);
}
console.log('全部符合预期：正例通过、反例全部被拦下。');
console.log('（这说明 verify-ipa.js 的 entitlement 解析器既不是坏的、也不是空的。）');
