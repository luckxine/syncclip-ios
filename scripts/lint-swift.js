// 轻量 Swift 源码体检：在没有 Swift 工具链的机器上（例如本机 Windows）
// 先把结构性错误扫出来，别等 CI 跑完才发现。
//
//   node scripts/lint-swift.js
//
// 检查项：
//   1. 花括号 / 圆括号 / 方括号配平
//   2. #if / #else / #endif 配平
//   3. 明显的非法写法：async 函数带 inout 参数（Swift 不允许）
//   4. 同一个 switch 的不同 case 里重复声明同名变量
//      —— 各 case 是否共享作用域在语言层面存在歧义，这里一律要求用不同名字，零成本避坑
//   5. **跨模块符号引用了但没 import** —— 这条是真踩过的坑：
//      BackgroundKeeper.swift 用了 SCLog 却只 import 了 Foundation/AVFoundation。
//      本地没有编译器时完全看不出，CI 上第一次编译才报 "cannot find 'SCLog' in scope"。
//      这里按「符号定义索引 → 提供它的模块」静态查出来，而不是猜前缀。
//
// 注意：这只是轻量体检，真正的编译验证只能在 macOS + Xcode 上做。

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
// lint 的目标（可以传一个目录或单个文件用于自测；默认扫仓库的 Sources/）
const SRC = path.resolve(process.argv[2] || path.join(ROOT, 'Sources'));
// 符号索引**始终**从整个项目的 Sources 建，不能只扫 lint 目标：
// 只给一个文件时（自测场景），模块归属根本算不出来，第五项检查会静默空转 —— 那就等于没检查。
const INDEX_ROOT = path.resolve(process.argv[3] || path.join(ROOT, 'Sources'));

function listSwift(target) {
    const st = fs.statSync(target);
    if (st.isFile()) return target.endsWith('.swift') ? [target] : [];
    return walk(target);
}

function walk(dir) {
    const out = [];
    for (const name of fs.readdirSync(dir)) {
        const p = path.join(dir, name);
        const st = fs.statSync(p);
        if (st.isDirectory()) out.push(...walk(p));
        else if (name.endsWith('.swift')) out.push(p);
    }
    return out;
}

/// 把注释和字符串字面量替换成空格（保留换行），避免括号计数被字面量里的符号干扰
function strip(src) {
    const out = src.split('');
    const n = src.length;
    const blank = (from, to) => {
        for (let k = from; k < to && k < n; k++) if (out[k] !== '\n') out[k] = ' ';
    };

    let i = 0;
    while (i < n) {
        const c = src[i];

        if (c === '/' && src[i + 1] === '/') {
            let j = i;
            while (j < n && src[j] !== '\n') j++;
            blank(i, j); i = j; continue;
        }
        if (c === '/' && src[i + 1] === '*') {
            let j = i + 2, depth = 1;
            while (j < n && depth > 0) {
                if (src[j] === '/' && src[j + 1] === '*') { depth++; j += 2; continue; }
                if (src[j] === '*' && src[j + 1] === '/') { depth--; j += 2; continue; }
                j++;
            }
            blank(i, j); i = j; continue;
        }
        if (c === '"' && src.startsWith('"""', i)) {
            let j = i + 3;
            while (j < n && !src.startsWith('"""', j)) j++;
            j = Math.min(n, j + 3);
            blank(i, j); i = j; continue;
        }
        if (c === '"') {
            let j = i + 1;
            while (j < n) {
                if (src[j] === '\\') { j += 2; continue; }
                if (src[j] === '"') { j++; break; }
                if (src[j] === '\n') break;
                j++;
            }
            blank(i, j); i = j; continue;
        }
        i++;
    }
    return out.join('');
}

/// 找出「同一 switch 的多个 case 里重复声明同名变量」
function findSwitchCaseCollisions(clean, problems) {
    const lines = clean.split('\n');
    let depth = 0;
    const stack = [];   // { bodyDepth, cases: Map<name, lineNo>, current: Map|null }

    lines.forEach((line, idx) => {
        const lineNo = idx + 1;
        const t = line.trim();
        const opens = (line.match(/\{/g) || []).length;
        const closes = (line.match(/\}/g) || []).length;

        // 已经进入 switch 体：
        //   - 行首深度 == bodyDepth 且以 case/default 开头 → 开一个新 case
        //   - 行首深度 == bodyDepth 的 let/var 声明 → 记进当前 case
        while (stack.length > 0 && depth < stack[stack.length - 1].bodyDepth) {
            stack.pop();
        }

        const top = stack[stack.length - 1];
        if (top && depth === top.bodyDepth) {
            if (/^(case\s|default\s*:)/.test(t)) {
                top.current = new Map();
                top.cases.push(top.current);
            }
            const dm = t.match(/^(?:let|var)\s+(\w+)\s*[:=]/);
            if (dm && top.current) {
                const name = dm[1];
                const prior = top.current.get(name);
                if (prior !== undefined) {
                    problems.push(`第 ${lineNo} 行：同一个 case 里重复声明 ${name}`);
                }
                for (const c of top.cases) {
                    if (c !== top.current && c.has(name)) {
                        problems.push(
                            `第 ${lineNo} 行：同一个 switch 的不同 case 里重复声明 ${name}` +
                            `（首次见第 ${c.get(name)} 行）—— 各 case 作用域规则有歧义，改用不同名字`);
                        break;
                    }
                }
                top.current.set(name, lineNo);
            }
        }

        // 本行出现 switch 且开了大括号 → 记下 switch 体深度
        if (/^switch\b/.test(t) && opens > closes) {
            stack.push({ bodyDepth: depth + 1, cases: [], current: null });
        }

        depth += opens - closes;
        if (depth < 0) depth = 0;

        while (stack.length > 0 && depth < stack[stack.length - 1].bodyDepth) {
            stack.pop();
        }
    });
}

/// 从文件路径推断它属于哪个 target（相对 INDEX_ROOT 的第一层目录名）
function moduleOf(file) {
    const rel = path.relative(INDEX_ROOT, file).split(path.sep);
    return rel.length > 1 ? rel[0] : null;
}

/// 扫一遍 Sources，建「public 符号名 → 所属模块」索引。
///
/// 只收**类型声明**和**文件顶层**的 public 函数/变量，不收类型成员。
/// 原因：成员（如 SCLog.info、SCInAppLog.append）在任何地方都得通过其类型名访问，
/// 所以把类型名索引到了就够了；把成员名也收进去只会产生一堆
/// 「使用了 SyncClipCore 的 append」这种噪声。
function buildSymbolIndex(files) {
    const index = new Map();
    const moduleNames = new Set();

    for (const file of files) {
        const owner = moduleOf(file);
        if (!owner) continue;
        moduleNames.add(owner);
        const clean = strip(fs.readFileSync(file, 'utf8'));

        // 类型声明：不计嵌套深度，因为嵌套类型也是通过外层类型名访问的
        for (const re of [
            /\b(?:public|open)\s+(?:final\s+)?(?:struct|class|enum|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/g,
        ]) {
            for (const m of clean.matchAll(re)) {
                if (!index.has(m[1])) index.set(m[1], owner);
            }
        }

        // 文件顶层的 public 函数/变量（跟嵌套深度追踪，只在深度 0 时收）
        let depth = 0;
        for (const line of clean.split('\n')) {
            if (depth === 0) {
                const m = line.match(
                    /^\s*(?:public|open)\s+(?:static\s+)?(?:func|var|let)\s+([A-Za-z_][A-Za-z0-9_]*)/);
                if (m && !index.has(m[1])) index.set(m[1], owner);
            }
            for (const ch of line) {
                if (ch === '{') depth++;
                else if (ch === '}') depth--;
            }
            if (depth < 0) depth = 0;
        }
    }

    return { index, moduleNames };
}

/// 找出「用了某个模块的符号，但没有 import 那个模块」
function findMissingImports(file, clean, symbolIndex, problems) {
    const imports = new Set();
    for (const m of clean.matchAll(/^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)/gm)) {
        imports.add(m[1]);
    }

    const self = moduleOf(file);
    const body = clean.replace(/^\s*import\s+.*$/gm, '');
    const seen = new Set();

    for (const [symbol, owner] of symbolIndex) {
        if (imports.has(owner)) continue;      // 已经 import 了提供它的模块
        if (owner === self) continue;          // 自己模块内，不用 import
        if (seen.has(symbol)) continue;
        // 用词边界匹配，避开 "SCLogLevel" 这类前缀相同的误判
        if (!new RegExp(`\\b${symbol}\\b`).test(body)) continue;
        seen.add(symbol);
        problems.push(`使用了 ${owner} 的 ${symbol}，但没有 \`import ${owner}\``);
    }
}

let failures = 0;
let files = 0;

const allFiles = listSwift(SRC);
// 符号索引用整个项目的源码，而不是 lint 目标
const { index: symbolIndex } = buildSymbolIndex(listSwift(INDEX_ROOT));

for (const file of allFiles) {
    files++;
    const src = fs.readFileSync(file, 'utf8');
    const clean = strip(src);
    const rel = path.relative(ROOT, file);
    const problems = [];

    // 1. 括号配平
    for (const [open, close, label] of [['{', '}', '花括号'], ['(', ')', '圆括号'], ['[', ']', '方括号']]) {
        let d = 0, min = 0;
        for (const ch of clean) {
            if (ch === open) d++;
            else if (ch === close) { d--; if (d < min) min = d; }
        }
        if (d !== 0) problems.push(`${label}不平衡（差 ${d}）`);
        else if (min < 0) problems.push(`${label}出现多余的闭合`);
    }

    // 2. 条件编译配平
    {
        let cond = 0;
        clean.split('\n').forEach((line, idx) => {
            const t = line.trim();
            if (/^#if\b/.test(t)) cond++;
            else if (/^#endif\b/.test(t)) { cond--; if (cond < 0) problems.push(`第 ${idx + 1} 行有多余的 #endif`); }
            else if (/^#else\b/.test(t) || /^#elseif\b/.test(t)) {
                if (cond === 0) problems.push(`第 ${idx + 1} 行的 #else/#elseif 不在 #if 里`);
            }
        });
        if (cond !== 0) problems.push(`#if / #endif 不平衡（差 ${cond}）`);
    }

    // 3. async 函数带 inout 参数
    {
        const declRe = /func\s+(\w+)\s*(?:<[^>]*>)?\s*\(([\s\S]*?)\)\s*(async)?/g;
        let m;
        while ((m = declRe.exec(clean)) !== null) {
            const [, name, params, isAsync] = m;
            if (isAsync && /\binout\b/.test(params)) {
                problems.push(`async 函数 ${name}(...) 使用了 inout 参数（Swift 不允许）`);
            }
        }
    }

    // 4. switch case 重名
    findSwitchCaseCollisions(clean, problems);

    // 5. 用了别的模块的符号却没 import
    findMissingImports(file, clean, symbolIndex, problems);

    if (problems.length > 0) {
        failures += problems.length;
        console.log(`❌ ${rel}`);
        problems.forEach(p => console.log(`     ${p}`));
    } else {
        console.log(`✅ ${rel}`);
    }
}

console.log('');
if (failures > 0) {
    console.error(`${failures} 个问题，共扫描 ${files} 个文件`);
    process.exit(1);
}
console.log(`未发现结构性问题（${files} 个文件）`);
console.log('（这只是轻量体检，真正的编译验证只能在 macOS + Xcode 上做。）');
