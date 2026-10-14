// 生成 App 图标 PNG。
//
// 为什么不用 Assets.xcassets：那需要 Xcode 的 actool 去编译，而本项目刻意
// 不依赖 Xcode 工程（构建脚本直接用 swiftc/SwiftPM）。iOS 支持直接在 .app 里
// 放 PNG 文件 + 在 Info.plist 里用 CFBundleIcons 声明，所以自己画一个更省事。
//
// 自带一个最小 PNG 编码器（IHDR/IDAT/IEND + CRC32，RGBA8），
// 图形用 SDF（有向距离场）光栅化，抗锯齿是免费的。
//
//   node scripts/make-icons.js [输出目录]     # 生成图标
//   node scripts/make-icons.js --preview      # 终端里用 ASCII 看一眼设计
//   node scripts/make-icons.js --selftest     # SDF 符号 + PNG 编码自检
//
// 图标设计：蓝色渐变底 + 白色剪贴板 + 板内一上一下两个箭头（表示双向同步）

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

// ===========================================================================
// 最小 PNG 编码器
// ===========================================================================

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

function chunk(type, data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length, 0);
    const typeBuf = Buffer.from(type, 'ascii');
    const crcBuf = Buffer.alloc(4);
    crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
    return Buffer.concat([len, typeBuf, data, crcBuf]);
}

/// rgba: Buffer，长度 w*h*4
function encodePNG(width, height, rgba) {
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(width, 0);
    ihdr.writeUInt32BE(height, 4);
    ihdr[8] = 8;    // 位深
    ihdr[9] = 6;    // 颜色类型 RGBA
    ihdr[10] = 0;   // 压缩方法
    ihdr[11] = 0;   // 滤波方法
    ihdr[12] = 0;   // 非隔行

    const stride = width * 4;
    const raw = Buffer.alloc((stride + 1) * height);
    for (let y = 0; y < height; y++) {
        raw[y * (stride + 1)] = 0;              // 每行滤波字节 0 = None
        rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
    }

    return Buffer.concat([
        Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        chunk('IHDR', ihdr),
        chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
        chunk('IEND', Buffer.alloc(0)),
    ]);
}

// ===========================================================================
// SDF 图形
/* 约定：返回值 < 0 表示在图形内部，单位与传入坐标一致 */
// ===========================================================================

function sdRoundRect(px, py, cx, cy, hw, hh, r) {
    const qx = Math.abs(px - cx) - hw + r;
    const qy = Math.abs(py - cy) - hh + r;
    const ax = Math.max(qx, 0), ay = Math.max(qy, 0);
    return Math.hypot(ax, ay) + Math.min(Math.max(qx, qy), 0) - r;
}

/// 等腰三角形：顶点 (cx, tipY)，底边在 baseY，半宽 halfW。要求 baseY > tipY。
///
/// 三条边取半平面的最大值：零等值线位置是准确的（顶点/边处为 0、内部为负、
/// 外部为正），用来做 1px 抗锯齿足够了。
///
/// 法线方向不手推：每条边算出法线后，用三角形重心代入校验一下，
/// 重心必须在负侧。手推符号很容易错，这里交给机器算。
function sdTriangle(px, py, cx, tipY, baseY, halfW) {
    const ax = cx, ay = tipY;                  // 顶点
    const bx = cx - halfW, by = baseY;         // 底左
    const ccx = cx + halfW, ccy = baseY;       // 底右
    const gx = (ax + bx + ccx) / 3;
    const gy = (ay + by + ccy) / 3;

    // 直线 P→Q 的有向距离，方向以「重心为负」为准
    const edge = (px_, py_, qx_, qy_, tx, ty) => {
        const ex = qx_ - px_, ey = qy_ - py_;
        const len = Math.hypot(ex, ey);
        const nx = -ey / len, ny = ex / len;
        const d = (tx - px_) * nx + (ty - py_) * ny;
        const dCentroid = (gx - px_) * nx + (gy - py_) * ny;
        return dCentroid < 0 ? d : -d;
    };

    const dBase = py - baseY;                                        // 重心必在底边之上
    const dLeft = edge(ax, ay, bx, by, px, py);                      // 顶点 → 底左
    const dRight = edge(ax, ay, ccx, ccy, px, py);                   // 顶点 → 底右

    return Math.max(dBase, dLeft, dRight);
}

/// 朝上的箭头（箭头在 tipY，箭尾在 tailY）
function sdArrowUp(px, py, cx, tipY, tailY, shaftHalfW, headHalfW, headH) {
    const baseY = tipY + headH;
    const head = sdTriangle(px, py, cx, tipY, baseY, headHalfW);
    const shaft = sdRoundRect(px, py, cx, (baseY + tailY) / 2,
                              shaftHalfW, (tailY - baseY) / 2, shaftHalfW);
    return Math.min(head, shaft);
}

/// 朝下的箭头：把 py 关于 [tipY, tailY] 的中点镜像一下就是朝上的
function sdArrowDown(px, py, cx, tipY, tailY, shaftHalfW, headHalfW, headH) {
    const mid = (tipY + tailY) / 2;
    return sdArrowUp(px, 2 * mid - py, cx, tipY, tailY, shaftHalfW, headHalfW, headH);
}

function smoothstep(edge0, edge1, x) {
    const t = Math.min(1, Math.max(0, (x - edge0) / (edge1 - edge0)));
    return t * t * (3 - 2 * t);
}

/// d 是像素单位的距离 → 覆盖率 0..1
function coverage(d, feather) {
    return 1 - smoothstep(-feather, feather, d);
}

function mixInto(dst, src, a) {
    if (a <= 0) return;
    for (let i = 0; i < 3; i++) dst[i] = dst[i] * (1 - a) + src[i] * a;
}

// ===========================================================================
// 图标几何（全部用 0..1 归一化坐标，方便任意分辨率渲染）
// ===========================================================================

const GEO = {
    body: { cx: 0.5, cy: 0.535, hw: 0.232, hh: 0.295, r: 0.058 },
    tab: { cx: 0.5, cy: 0.212, hw: 0.104, hh: 0.050, r: 0.034 },
    gap: { cx: 0.5, cy: 0.250, hw: 0.150, hh: 0.014, r: 0.010 },
    arrow: {
        dx: 0.082,           // 左右箭头相对中心的偏移
        topY: 0.345,
        botY: 0.720,
        shaftHalfW: 0.028,
        headHalfW: 0.076,
        headH: 0.075,
    },
};

const BLUE_TOP = [0x45, 0x8a, 0xf5];
const BLUE_BOTTOM = [0x1d, 0x4e, 0xd8];
const WHITE = [0xff, 0xff, 0xff];
// 箭头用深宝蓝而不是中蓝：既要压在白板上够醒目，又要和背景渐变的蓝区分得开
// （背景的蓝分量在 200 以上，箭头在 120 左右）
const ARROW = [0x0f, 0x2b, 0x78];

function renderIcon(size) {
    const out = Buffer.alloc(size * size * 4);
    const feather = Math.max(0.7, size / 220);

    const cxLeft = 0.5 - GEO.arrow.dx;
    const cxRight = 0.5 + GEO.arrow.dx;
    // 箭头落在板身内部才好看：左右不能超出板宽
    const arrowOuter = GEO.arrow.dx + GEO.arrow.headHalfW;
    if (arrowOuter > GEO.body.hw - 0.02) {
        throw new Error(`箭头超出板身：${arrowOuter.toFixed(3)} > ${GEO.body.hw}`);
    }

    for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
            const px = (x + 0.5) / size;
            const py = (y + 0.5) / size;

            // ---- 背景：竖直渐变 + 左上角柔光 ----
            const t = py;
            const rgb = [
                BLUE_TOP[0] * (1 - t) + BLUE_BOTTOM[0] * t,
                BLUE_TOP[1] * (1 - t) + BLUE_BOTTOM[1] * t,
                BLUE_TOP[2] * (1 - t) + BLUE_BOTTOM[2] * t,
            ];
            const halo = Math.max(0, 1 - Math.hypot(px - 0.18, py - 0.12) / 0.78);
            mixInto(rgb, WHITE, halo * halo * 0.24);

            // ---- 剪贴板板身 ----
            const body = sdRoundRect(px, py, GEO.body.cx, GEO.body.cy,
                                     GEO.body.hw, GEO.body.hh, GEO.body.r) * size;
            const bodyCov = coverage(body, feather);
            mixInto(rgb, WHITE, bodyCov);

            // ---- 板身顶部的一道凹槽：把「夹子」和「纸」分开 ----
            const gap = sdRoundRect(px, py, GEO.gap.cx, GEO.gap.cy,
                                    GEO.gap.hw, GEO.gap.hh, GEO.gap.r) * size;
            const gapColor = [
                BLUE_TOP[0] * 0.4 + BLUE_BOTTOM[0] * 0.6,
                BLUE_TOP[1] * 0.4 + BLUE_BOTTOM[1] * 0.6,
                BLUE_TOP[2] * 0.4 + BLUE_BOTTOM[2] * 0.6,
            ];
            mixInto(rgb, gapColor, coverage(gap, feather) * bodyCov);

            // ---- 夹子（画在板身之上，上缘探出板外）----
            const tab = sdRoundRect(px, py, GEO.tab.cx, GEO.tab.cy,
                                    GEO.tab.hw, GEO.tab.hh, GEO.tab.r) * size;
            mixInto(rgb, WHITE, coverage(tab, feather));

            // ---- 板内两个箭头 ----
            const up = sdArrowUp(px, py, cxLeft,
                                 GEO.arrow.topY, GEO.arrow.botY,
                                 GEO.arrow.shaftHalfW, GEO.arrow.headHalfW, GEO.arrow.headH) * size;
            const down = sdArrowDown(px, py, cxRight,
                                     GEO.arrow.topY, GEO.arrow.botY,
                                     GEO.arrow.shaftHalfW, GEO.arrow.headHalfW, GEO.arrow.headH) * size;
            mixInto(rgb, ARROW, coverage(up, feather));
            mixInto(rgb, ARROW, coverage(down, feather));

            const o = (y * size + x) * 4;
            out[o] = Math.round(Math.min(255, Math.max(0, rgb[0])));
            out[o + 1] = Math.round(Math.min(255, Math.max(0, rgb[1])));
            out[o + 2] = Math.round(Math.min(255, Math.max(0, rgb[2])));
            out[o + 3] = 255;
        }
    }
    return out;
}

// ===========================================================================
// 自检
// ===========================================================================

/// SDF 必须满足：内部点 < 0、外部点 > 0、边界点 ≈ 0
function sdfSelfTest() {
    const problems = [];
    const check = (label, got, wantNegative) => {
        if (wantNegative && !(got < 0)) problems.push(`${label}：应为内部（负），实际 ${got.toFixed(4)}`);
        if (!wantNegative && !(got > 0)) problems.push(`${label}：应为外部（正），实际 ${got.toFixed(4)}`);
    };

    // 圆角矩形
    const r = { cx: 0.5, cy: 0.5, hw: 0.2, hh: 0.3, r: 0.05 };
    check('圆角矩形中心', sdRoundRect(0.5, 0.5, r.cx, r.cy, r.hw, r.hh, r.r), true);
    check('圆角矩形右侧外', sdRoundRect(0.75, 0.5, r.cx, r.cy, r.hw, r.hh, r.r), false);
    check('圆角矩形角外', sdRoundRect(0.75, 0.85, r.cx, r.cy, r.hw, r.hh, r.r), false);
    check('圆角矩形角内', sdRoundRect(0.55, 0.65, r.cx, r.cy, r.hw, r.hh, r.r), true);

    // 三角形（顶点在上）
    const tri = (x, y) => sdTriangle(x, y, 0.5, 0.3, 0.7, 0.2);
    check('三角形重心', tri(0.5, 0.567), true);
    check('三角形顶点上方', tri(0.5, 0.2), false);
    check('三角形左下外', tri(0.2, 0.6), false);
    check('三角形右下外', tri(0.8, 0.6), false);
    check('三角形底边下方', tri(0.5, 0.75), false);
    // 边界上应该接近 0
    const nearEdge = tri(0.5, 0.7);
    if (Math.abs(nearEdge) > 1e-9) problems.push(`三角形底边上的点应为 0，实际 ${nearEdge}`);

    // 箭头
    const up = (x, y) => sdArrowUp(x, y, 0.4, 0.35, 0.7, 0.024, 0.068, 0.072);
    check('箭头轴上', up(0.4, 0.6), true);
    check('箭头尖上方', up(0.4, 0.3), false);
    check('箭头轴左侧外', up(0.33, 0.6), false);

    // 朝下箭头：轴下方应该在里面，轴上方应该在外面
    const down = (x, y) => sdArrowDown(x, y, 0.6, 0.35, 0.7, 0.024, 0.068, 0.072);
    check('下箭头轴上', down(0.6, 0.5), true);
    check('下箭头尖下方', down(0.6, 0.75), false);

    return problems;
}

/// PNG 结构自检：解回来核对 CRC、尺寸、IDAT 长度、滤波字节
function pngSelfTest(buf, expectW, expectH) {
    const problems = [];
    const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    for (let i = 0; i < 8; i++) {
        if (buf[i] !== sig[i]) { problems.push('PNG 魔数不对'); break; }
    }

    let off = 8;
    const chunks = [];
    let idat = Buffer.alloc(0);

    while (off + 8 <= buf.length) {
        const len = buf.readUInt32BE(off);
        const type = buf.slice(off + 4, off + 8).toString('ascii');
        const data = buf.slice(off + 8, off + 8 + len);
        const crc = buf.readUInt32BE(off + 8 + len);
        const actual = crc32(Buffer.concat([Buffer.from(type, 'ascii'), data]));
        if (crc !== actual) problems.push(`chunk ${type} 的 CRC 不对`);
        chunks.push(type);
        if (type === 'IDAT') idat = Buffer.concat([idat, data]);
        off += 12 + len;
        if (type === 'IEND') break;
    }

    if (chunks[0] !== 'IHDR') problems.push('第一个 chunk 不是 IHDR');
    if (chunks[chunks.length - 1] !== 'IEND') problems.push('最后一个 chunk 不是 IEND');

    const w = buf.readUInt32BE(16), h = buf.readUInt32BE(20);
    if (w !== expectW || h !== expectH) problems.push(`尺寸不对：${w}x${h}，期望 ${expectW}x${expectH}`);

    const raw = zlib.inflateSync(idat);
    const expected = (w * 4 + 1) * h;
    if (raw.length !== expected) problems.push(`IDAT 解压后 ${raw.length} 字节，期望 ${expected}`);
    for (let y = 0; y < h; y++) {
        if (raw[y * (w * 4 + 1)] !== 0) { problems.push(`第 ${y} 行滤波字节非 0`); break; }
    }
    return problems;
}

// ===========================================================================
// ASCII 预览（没有图形界面时唯一能"看见"设计的办法）
// ===========================================================================

function asciiPreview(cols = 58) {
    const rows = Math.round(cols / 2);
    const size = 512;
    const img = renderIcon(size);
    const ramp = ' .:-=+*#%@';
    const lines = [];
    for (let r = 0; r < rows; r++) {
        let line = '';
        for (let c = 0; c < cols; c++) {
            let sum = 0, n = 0;
            const x0 = Math.floor(c * size / cols), x1 = Math.max(x0 + 1, Math.floor((c + 1) * size / cols));
            const y0 = Math.floor(r * size / rows), y1 = Math.max(y0 + 1, Math.floor((r + 1) * size / rows));
            for (let y = y0; y < y1; y += 2) {
                for (let x = x0; x < x1; x += 2) {
                    const o = (y * size + x) * 4;
                    sum += img[o] * 0.299 + img[o + 1] * 0.587 + img[o + 2] * 0.114;
                    n++;
                }
            }
            const lum = n ? sum / n / 255 : 0;
            line += ramp[Math.min(ramp.length - 1, Math.round(lum * (ramp.length - 1)))];
        }
        lines.push(line);
    }
    return lines.join('\n');
}

// ===========================================================================
// main
// ===========================================================================

const args = process.argv.slice(2);

if (args.includes('--preview')) {
    const sdfProblems = sdfSelfTest();
    if (sdfProblems.length) {
        console.error('SDF 自检失败：\n  ' + sdfProblems.join('\n  '));
        process.exit(1);
    }
    console.log(asciiPreview(58));
    process.exit(0);
}

if (args.includes('--selftest')) {
    let failures = 0;
    const sdfProblems = sdfSelfTest();
    console.log('[SDF 几何]');
    if (sdfProblems.length) { failures += sdfProblems.length; sdfProblems.forEach(p => console.log('  ❌ ' + p)); }
    else console.log('  ✅ 内部/外部/边界符号全部正确');

    console.log('[PNG 编码]');
    for (const size of [120, 180, 1024]) {
        const png = encodePNG(size, size, renderIcon(size));
        const problems = pngSelfTest(png, size, size);
        if (problems.length) { failures += problems.length; problems.forEach(p => console.log(`  ❌ ${size}: ${p}`)); }
        else console.log(`  ✅ ${size}×${size}  ${(png.length / 1024).toFixed(1)} KB`);
    }

    // 图标内容自检：白/蓝占比应该合理，不能是纯色也不能糊成一团
    console.log('[内容分布]');
    const size = 256;
    const img = renderIcon(size);
    let white = 0, dark = 0, bg = 0;
    for (let i = 0; i < size * size; i++) {
        const r = img[i * 4], g = img[i * 4 + 1], b = img[i * 4 + 2];
        if (r > 230 && g > 230 && b > 230) white++;
        else if (r < 70 && g < 80 && b < 170) dark++;
        else bg++;
    }
    const pct = (n) => (n / (size * size) * 100).toFixed(1) + '%';
    console.log(`  白（剪贴板）${pct(white)}  深蓝（箭头）${pct(dark)}  底色 ${pct(bg)}`);
    if (white < size * size * 0.15) { console.log('  ❌ 白色区域太小，剪贴板可能没画出来'); failures++; }
    if (white > size * size * 0.6) { console.log('  ❌ 白色区域太大，图形可能糊成一块'); failures++; }
    if (dark < size * size * 0.005) { console.log('  ❌ 几乎看不到箭头'); failures++; }

    if (failures) { console.error(`\n${failures} 个问题`); process.exit(1); }
    console.log('\n全部通过');
    process.exit(0);
}

const outDir = args[0] && !args[0].startsWith('--') ? args[0] : 'Resources';
fs.mkdirSync(outDir, { recursive: true });

const targets = [
    { name: 'AppIcon60x60@2x.png', size: 120 },   // iPhone 主屏
    { name: 'AppIcon60x60@3x.png', size: 180 },
    { name: 'AppIcon1024.png', size: 1024 },      // 商店/展示用
];

console.log(`生成图标到 ${outDir}/`);

let failures = 0;
for (const t of targets) {
    const png = encodePNG(t.size, t.size, renderIcon(t.size));
    fs.writeFileSync(path.join(outDir, t.name), png);
    const problems = pngSelfTest(png, t.size, t.size);
    if (problems.length) {
        failures += problems.length;
        console.log(`  ❌ ${t.name}  ${problems.join('；')}`);
    } else {
        console.log(`  ✅ ${t.name}  ${t.size}×${t.size}  ${(png.length / 1024).toFixed(1)} KB`);
    }
}

if (failures > 0) {
    console.error(`\n${failures} 个问题`);
    process.exit(1);
}
console.log('\n完成');
