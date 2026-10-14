// deb 结构校验器：不用 ar / dpkg-deb，直接按规范解析 deb，用来在本机
// （macOS / Linux / Windows 都能跑）验一遍打包结果是否正确。
//
//   node scripts/verify-deb.js dist/xxx.deb
//
// 校验项：
//   - ar 魔数与成员顺序（必须是 debian-binary, control.tar.gz, data.tar.gz）
//   - debian-binary 内容为 "2.0\n"
//   - control.tar.gz 里必须有合法的 control（含 Package / Version / Architecture），
//     且**不能**混进 data 的东西
//   - data.tar.gz 必须有二进制与 LaunchAgent，且**二进制权限位必须是 0755**
//     （这是最容易被漏掉的一项：权限位不对，装上去根本执行不了）
//   - data 里不能混进 DEBIAN/

const fs = require('fs');
const zlib = require('zlib');

const file = process.argv[2];
if (!file) {
    console.error('用法：node scripts/verify-deb.js <path/to.deb>');
    process.exit(2);
}

const buf = fs.readFileSync(file);
let failures = [];
let checks = 0;

function check(cond, label, detail = '') {
    checks++;
    if (cond) {
        console.log(`  ✅ ${label}${detail ? '  ' + detail : ''}`);
    } else {
        console.log(`  ❌ ${label}${detail ? '  ' + detail : ''}`);
        failures.push(label);
    }
}

// ---- ar ----
console.log(`\n检查 ${file}（${(buf.length / 1024).toFixed(1)} KB）\n`);
console.log('[ar 外壳]');
check(buf.slice(0, 8).toString('ascii') === '!<arch>\n', 'ar 魔数 !<arch>');

const members = [];
let off = 8;
while (off + 60 <= buf.length) {
    const hdr = buf.slice(off, off + 60).toString('ascii');
    // 名字字段按空格补齐；兼容尾部 '/'（GNU ar 的写法）
    const name = hdr.slice(0, 16).replace(/\s+$/, '').replace(/\/$/, '');
    if (!name) break;
    const size = parseInt(hdr.slice(48, 58).trim(), 10);
    if (!Number.isFinite(size) || size < 0) break;
    members.push({ name, size, data: buf.slice(off + 60, off + 60 + size) });
    off += 60 + size + (size % 2);
}

check(members.length === 3, '成员数量为 3', `实际 ${members.length}`);
check(members[0]?.name === 'debian-binary', '第一个成员是 debian-binary');
check(members[1]?.name === 'control.tar.gz', '第二个成员是 control.tar.gz');
check(members[2]?.name === 'data.tar.gz', '第三个成员是 data.tar.gz');
check(members[0]?.data.toString() === '2.0\n', 'debian-binary 内容为 "2.0\\n"');

// ---- tar 解析 ----
function parseTar(raw) {
    const entries = [];
    let p = 0;
    while (p + 512 <= raw.length) {
        const h = raw.slice(p, p + 512);
        if (h.every(b => b === 0)) break;

        const name = h.slice(0, 100).toString('utf8').replace(/\0.*$/, '');
        const modeStr = h.slice(100, 108).toString('ascii').replace(/\0.*$/, '').trim();
        const sizeStr = h.slice(124, 136).toString('ascii').replace(/\0.*$/, '').trim();
        const type = h.slice(156, 157).toString('ascii');
        const magic = h.slice(257, 262).toString('ascii');

        const mode = parseInt(modeStr || '0', 8);
        const size = parseInt(sizeStr || '0', 8);
        const data = raw.slice(p + 512, p + 512 + size);

        entries.push({ name, mode, size, type, magic, data });
        p += 512 + Math.ceil(size / 512) * 512;
    }
    return entries;
}

console.log('\n[control.tar.gz]');
let controlEntries = [];
try {
    controlEntries = parseTar(zlib.gunzipSync(members[1].data));
    check(true, '可解压解析');
} catch (e) {
    check(false, '可解压解析', e.message);
}

const controlFile = controlEntries.find(e => e.name === './control' || e.name === 'control');
check(!!controlFile, '存在 control 文件');
if (controlFile) {
    const text = controlFile.data.toString('utf8');
    for (const key of ['Package:', 'Version:', 'Architecture:', 'Depends:']) {
        check(text.includes(key), `control 含 ${key}`);
    }
    const pkg = (text.match(/^Package:\s*(.+)$/m) || [])[1];
    const ver = (text.match(/^Version:\s*(.+)$/m) || [])[1];
    const arch = (text.match(/^Architecture:\s*(.+)$/m) || [])[1];
    check(pkg === 'com.cxk.syncclipd', 'Package 名称正确', pkg);
    check(/^iphoneos-arm64(e?)$/.test(arch || ''), 'Architecture 合法', arch);
    console.log(`     版本 ${ver}  架构 ${arch}`);
}
check(!controlEntries.some(e => e.name.includes('/var/')),
      'control.tar.gz 里没有混进 data 内容');

console.log('\n[data.tar.gz]');
let dataEntries = [];
try {
    dataEntries = parseTar(zlib.gunzipSync(members[2].data));
    check(true, '可解压解析');
} catch (e) {
    check(false, '可解压解析', e.message);
}

const byName = new Map(dataEntries.map(e => [e.name.replace(/^\.\//, ''), e]));
const bin = byName.get('var/jb/usr/bin/syncclipd');
const agent = byName.get('var/jb/Library/LaunchAgents/com.cxk.syncclipd.plist');

check(!!bin, '包含 var/jb/usr/bin/syncclipd');
check(!!agent, '包含 var/jb/Library/LaunchAgents/com.cxk.syncclipd.plist');
check(!dataEntries.some(e => e.name.replace(/^\.\//, '').startsWith('DEBIAN')),
      'data.tar.gz 里没有混进 DEBIAN 目录');

if (bin) {
    // 最容易被漏掉的一项：权限位不对 = 装上去执行不了
    check(bin.mode === 0o755, '二进制权限位为 0755', `实际 0${bin.mode.toString(8)}`);
    check(bin.size > 1024, '二进制体积合理', `${bin.size} 字节`);

    // Mach-O 魔数：确认这确实是个可执行文件，而不是空文件或文本
    const m = bin.data.slice(0, 4);
    const isMachO = (m[0] === 0xcf && m[1] === 0xfa && m[2] === 0xed && m[3] === 0xfe) || // MH_MAGIC_64 (LE)
                    (m[0] === 0xfe && m[1] === 0xed && m[2] === 0xfa && m[3] === 0xcf);   // MH_MAGIC_64 (BE)
    check(isMachO, '二进制是 Mach-O 64 位可执行文件',
          `魔数 ${[...m].map(b => b.toString(16).padStart(2, '0')).join(' ')}`);
}

if (agent) {
    const plist = agent.data.toString('utf8');
    check(plist.includes('com.cxk.syncclipd'), 'LaunchAgent Label 正确');
    check(plist.includes('ProgramArguments'), 'LaunchAgent 含 ProgramArguments');
    check(plist.includes('/var/jb/usr/bin/syncclipd'), 'LaunchAgent 指向 /var/jb 下的二进制');
    check(plist.includes('RunAtLoad'), 'LaunchAgent 设置了 RunAtLoad');
}

// ---- 汇总 ----
console.log('');
if (failures.length > 0) {
    console.error(`失败：${failures.length}/${checks} 项未通过`);
    failures.forEach(f => console.error(`  - ${f}`));
    process.exit(1);
}
console.log(`全部通过（${checks} 项检查）`);
