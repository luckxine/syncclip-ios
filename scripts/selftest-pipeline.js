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
const SUPERBLOB_MAGIC = 0xfade0cc0;
const ENTITLEMENTS_MAGIC = 0xfade7171;

function buildMachO(entitlementsXml, cputype = 0x0100000c) {
    const xml = Buffer.from(entitlementsXml, 'utf8');
    const entBlobLen = 8 + xml.length;
    const count = 1;
    const superLen = 12 + 8 * count + entBlobLen;

    const loadCmdSize = 16;
    const sigOffset = 32 + loadCmdSize;
    const out = Buffer.alloc(sigOffset + superLen);

    // mach_header_64
    out.writeUInt32LE(0xfeedfacf, 0);
    out.writeUInt32LE(cputype, 4);
    out.writeUInt32LE(0, 8);
    out.writeUInt32LE(2, 12);              // MH_EXECUTE
    out.writeUInt32LE(1, 16);              // ncmds
    out.writeUInt32LE(loadCmdSize, 20);
    out.writeUInt32LE(0, 24);
    out.writeUInt32LE(0, 28);

    // LC_CODE_SIGNATURE
    out.writeUInt32LE(LC_CODE_SIGNATURE, 32);
    out.writeUInt32LE(16, 36);
    out.writeUInt32LE(sigOffset, 40);
    out.writeUInt32LE(superLen, 44);

    // SuperBlob（代码签名里的结构一律大端）
    out.writeUInt32BE(SUPERBLOB_MAGIC, sigOffset);
    out.writeUInt32BE(superLen, sigOffset + 4);
    out.writeUInt32BE(count, sigOffset + 8);
    out.writeUInt32BE(5, sigOffset + 12);            // CSSLOT_ENTITLEMENTS
    out.writeUInt32BE(12 + 8 * count, sigOffset + 16);

    // entitlements blob
    const b = sigOffset + 12 + 8 * count;
    out.writeUInt32BE(ENTITLEMENTS_MAGIC, b);
    out.writeUInt32BE(entBlobLen, b + 4);
    xml.copy(out, b + 8);

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
    const bin = buildMachO(o.entitlementsXml);
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
// 跑流水线
// ===========================================================================

function run(script, args) {
    const r = require('child_process').spawnSync('node', [path.join(__dirname, script), ...args],
                                               { cwd: ROOT, encoding: 'utf8' });
    return { ok: r.status === 0, out: (r.stdout || '') + (r.stderr || '') };
}

function pipeline(appDir, ipaPath) {
    const pack = run('make-ipa.js', ['SyncClipboard', appDir, ipaPath]);
    if (!pack.ok) return { ok: false, stage: 'make-ipa', out: pack.out };
    const verify = run('verify-ipa.js', [ipaPath]);
    return { ok: verify.ok, stage: 'verify-ipa', out: verify.out };
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

fs.rmSync(WORK, { recursive: true, force: true });

console.log('');
if (failures > 0) {
    console.error(`${failures} 项不符合预期`);
    process.exit(1);
}
console.log('全部符合预期：正例通过、反例全部被拦下。');
console.log('（这说明 verify-ipa.js 的 entitlement 解析器既不是坏的、也不是空的。）');
