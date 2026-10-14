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

/// 真正的词法体检：按 Swift 的字符串/插值规则扫一遍。
///
/// 为什么要这么较真：`strip()` 遇到未闭合的字符串就 break 掉，
/// 导致后面的括号根本没被计入 —— 而这类错误的结果往往是一个余下的
/// 全角 `）` 顶替了本应闭合插值的 ASCII `)`。这种错误括号计数看起来是平的，
/// 本地完全看不出来，CI 上才报 “cannot find ')' to match opening '('”。
///
/// 这里用一个带状态机的小扫描器，把三种情况变成可报的：
///   1. 单行字符串在换行前没闭合
///   2. 字符串插值 `\(` 没被 ASCII `)` 闭合
///   3. 插值里跨行（单行字符串里不允许）
function lexCheck(src) {
    const problems = [];
    let line = 1;
    let i = 0;
    let mode = 'code';              // code | string | multiline
    let stringStartLine = 1;
    const brackets = [];            // 括号栈，存 { char, line }
    const interps = [];             // 未闭合的插值：{ depth, returnMode, line }

    const pairOf = { ')': '(', ']': '[', '}': '{' };

    while (i < src.length) {
        const c = src[i];

        if (mode === 'multiline') {
            if (c === '\n') line++;
            // 多行字符串里也能插值
            if (c === '\\' && src[i + 1] === '(') {
                interps.push({ depth: brackets.length, returnMode: 'multiline', line });
                mode = 'code';
                i += 2;
                continue;
            }
            if (src.startsWith('"""', i)) { mode = 'code'; i += 3; continue; }
            i++;
            continue;
        }

        if (mode === 'string') {
            // 先把插值挑出来：`\\(` 不能被当成普通转义符对儿跳过，
            // 否则插值永远不会被识别，整个后面的扫描就全错了。
            if (c === '\\' && src[i + 1] === '(') {
                interps.push({ depth: brackets.length, returnMode: 'string', line });
                mode = 'code';
                i += 2;
                continue;
            }
            if (c === '\\') { i += 2; continue; }         // 普通转义
            if (c === '"') { mode = 'code'; i++; continue; }
            if (c === '\n') {
                problems.push(`第 ${stringStartLine} 行的字符串字面量没有闭合`);
                mode = 'code';
                continue;                                   // 不消费换行，让外层处理
            }
            i++;
            continue;
        }

        // ---- code 模式 ----
        if (c === '/' && src[i + 1] === '/') {
            while (i < src.length && src[i] !== '\n') i++;
            continue;
        }
        if (c === '/' && src[i + 1] === '*') {
            let depth = 1;
            i += 2;
            while (i < src.length && depth > 0) {
                if (src[i] === '\n') line++;
                if (src.startsWith('/*', i)) { depth++; i += 2; continue; }
                if (src.startsWith('*/', i)) { depth--; i += 2; continue; }
                i++;
            }
            continue;
        }
        if (src.startsWith('"""', i)) { mode = 'multiline'; i += 3; continue; }
        if (c === '"') { mode = 'string'; stringStartLine = line; i++; continue; }

        if (c === '(' || c === '[' || c === '{') {
            brackets.push({ char: c, line });
            i++;
            continue;
        }

        if (c === ')' || c === ']' || c === '}') {
            // 这个 ')' 是否恰好关掉一个未闭合的插值？
            //
            // 注意：插值的开头 `\(` 并没有入括号栈（开头的 `(` 是跟 `\` 一起
            // 被消掉的），所以这个 `)` **不能**再去弹括号栈 ——
            // 它只负责闭合插值。少写这个 continue 会让栈整体错位，
            // 之后整篇文件都报“括号不配对”。
            if (c === ')' && interps.length > 0 &&
                interps[interps.length - 1].depth === brackets.length) {
                mode = interps.pop().returnMode;   // 回到它所在的那个字符串里
                i++;
                continue;
            }

            const top = brackets.pop();
            if (!top) {
                problems.push(`第 ${line} 行多了一个 '${c}'`);
            } else if (top.char !== pairOf[c]) {
                problems.push(`第 ${line} 行的 '${c}' 与第 ${top.line} 行的 '${top.char}' 不配对`);
            }
            i++;
            continue;
        }

        if (c === '\n') {
            line++;
            // 插值里跨行：单行字符串中不允许（多行字符串里的插值可以）
            // 每个帧只报一次，否则后面每一行都会重复刷屏
            for (const frame of interps) {
                if (frame.returnMode === 'string' && frame.line < line && !frame.reported) {
                    frame.reported = true;
                    problems.push(
                        `第 ${frame.line} 行的字符串插值 \\( 到行尾都没被 ASCII ')' 闭合`
                        + `（常见原因：误用了全角 '）'）`);
                }
            }
            i++;
            continue;
        }

        i++;
    }

    if (mode === 'string') {
        problems.push(`第 ${stringStartLine} 行的字符串字面量到文件尾都没闭合`);
    }
    if (mode === 'multiline') {
        problems.push('多行字符串字面量 """ 到文件尾都没闭合');
    }
    for (const frame of interps) {
        problems.push(`第 ${frame.line} 行的插值 \\( 到文件尾都没被 ')' 闭合`);
    }
    for (const b of brackets) {
        problems.push(`第 ${b.line} 行的 '${b.char}' 到文件尾都没闭合`);
    }

    return problems;
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

// ---------------------------------------------------------------------------
// iOS 16+ 专属 API
//
// 目标是最低 iOS 15.5，所以这些都不能用。手动 grep 过好几轮，干脆固化成检查：
// 已经在 .fontWeight()、.bold()、NavigationStack 上各撞过一次。
// ---------------------------------------------------------------------------

const NEWER_THAN_IOS15 = [
    { re: /\.fontWeight\s*\(/, note: 'View 上的 .fontWeight() 是 iOS 16+。改用 .font(.system(size:weight:))，或把它加在 Text 上' },
    { re: /\.bold\s*\(\s*\)/, note: 'View 上的 .bold() 是 iOS 16+。改用 .font(.system(size:weight:))' },
    { re: /\bNavigationStack\b/, note: 'iOS 16+。用 NavigationView + .navigationViewStyle(.stack)' },
    { re: /\.presentationDetents\s*\(/, note: 'iOS 16+' },
    { re: /\.presentationBackground\s*\(/, note: 'iOS 16.4+' },
    { re: /\.scrollContentBackground\s*\(/, note: 'iOS 16+' },
    { re: /\bLabeledContent\s*\(/, note: 'iOS 16+。改用 HStack { Text; Spacer; Text }' },
    { re: /\bContentUnavailableView\b/, note: 'iOS 17+。用自建的 SCEmptyState' },
    { re: /\.reservesSpace\b/, note: 'iOS 16+' },
    { re: /\.fontDesign\s*\(/, note: 'iOS 16+' },
    { re: /\bGrid\s*\(/, note: 'iOS 16+。用 LazyVGrid（iOS 14+）' },
    { re: /\bGridRow\s*\(/, note: 'iOS 16+' },
    { re: /\.toolbarBackground\s*\(/, note: 'iOS 16+' },
    { re: /\.contentMargins\s*\(/, note: 'iOS 17+' },
    { re: /\bShareLink\s*\(/, note: 'iOS 16+。用 UIActivityViewController' },
    { re: /\.scrollIndicators\s*\(/, note: 'iOS 16+' },
    { re: /\.containerRelativeFrame\s*\(/, note: 'iOS 17+' },
];

function findNewerAPIs(clean, problems) {
    for (const entry of NEWER_THAN_IOS15) {
        if (entry.re.test(clean)) {
            problems.push(`用了 iOS 16+ 的 API（目标是 15.5）：${entry.note}`);
        }
    }
}

/// 系统框架的符号 → 必须直接 import 的模块。
///
/// 只列会真实踩坑的：UIKit 的符号不能指望 SwiftUI 帮忙转出，
/// 漏了 import UIKit 就只有到 CI 上才发现。
const SYSTEM_MODULES = [
    {
        module: 'UIKit',
        // SwiftUI 不保证转出这些，所以要求直接 import UIKit
        reexportedBy: [],
        symbols: ['UIColor', 'UIImage', 'UIApplication', 'UIKeyboardType', 'UIPasteboard',
                  'UIView', 'UIScreen', 'UIFont', 'UIDevice', 'UIScene', 'UIInterfaceOrientation',
                  'UIAlertController', 'UIViewController'],
    },
    {
        module: 'Foundation',
        // SwiftUI 与 UIKit 都会转出 Foundation，所以有其中之一也算数
        reexportedBy: ['SwiftUI', 'UIKit'],
        symbols: ['Bundle', 'FileManager', 'URLComponents', 'URLRequest', 'URLSession',
                  'JSONDecoder', 'JSONEncoder', 'DateFormatter', 'ISO8601DateFormatter',
                  'NotificationCenter', 'UserDefaults', 'RelativeDateTimeFormatter',
                  'PropertyListSerialization', 'UUID', 'CommandLine', 'ProcessInfo'],
    },
];

/// 找出「用了系统框架的符号但没 import 对应模块」
function findMissingSystemImports(clean, problems) {
    const imports = new Set();
    for (const m of clean.matchAll(/^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)/gm)) {
        imports.add(m[1]);
    }

    const body = clean.replace(/^\s*import\s+.*$/gm, '');

    for (const entry of SYSTEM_MODULES) {
        if (imports.has(entry.module)) continue;
        if (entry.reexportedBy.some((m) => imports.has(m))) continue;
        for (const symbol of entry.symbols) {
            if (new RegExp(`\\b${symbol}\\b`).test(body)) {
                problems.push(`使用了 ${entry.module} 的 ${symbol}，但没有 \`import ${entry.module}\``);
                break;   // 每个模块只报一次，免得刷屏
            }
        }
    }
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
    // 所有类型声明（含 internal），symbol → Set<module>
    const allTypes = new Map();
    // 其中 public/open 的，symbol → Set<module>
    const publicTypes = new Map();

    const add = (map, symbol, owner) => {
        if (!map.has(symbol)) map.set(symbol, new Set());
        map.get(symbol).add(owner);
    };

    for (const file of files) {
        const owner = moduleOf(file);
        if (!owner) continue;
        moduleNames.add(owner);
        const clean = strip(fs.readFileSync(file, 'utf8'));

        // 类型声明：不计嵌套深度，因为嵌套类型也是通过外层类型名访问的。
        // 访问修饰符必须用捕获组取 —— 不能用 `m.index - 12` 去回看：
        // 匹配本身就是从修饰符开始的，往回看只会看到前一个声明。
        // （写错过一次：把源码里所有 public 类型都当成 internal，报了 52 个假问题。）
        for (const m of clean.matchAll(
            /\b(?:(public|open|private|fileprivate|internal)\s+)?(?:final\s+)?(?:struct|class|enum|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/g)) {
            const access = m[1] || 'internal';
            const symbol = m[2];
            const isPublic = access === 'public' || access === 'open';
            if (isPublic) {
                if (!index.has(symbol)) index.set(symbol, owner);
                add(publicTypes, symbol, owner);
            }
            add(allTypes, symbol, owner);
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

    return { index, moduleNames, allTypes, publicTypes };
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

/// 找出「用了别的模块的**内部**类型」。
///
/// 这一类错误和「忘了 import」长得像，但完全不同：internal 是模块级可见性，
/// **光加 import 也救不了**，得把那个类型挪到共享模块去。
/// 真踩过一次：App 侧写了 `ProbeTunnelProvider.json(…)`，而那个类型在 appex 模块里，
/// 是本模块内部的工具函数 —— 本地 lint 没发现，到 CI 上变成四个编译错误。
/// 症状是 `cannot find 'ProbeTunnelProvider' in scope`，看起来像少了个 import，
/// 很容易顺手去加 import 然后继续碰壁。
function findCrossModuleInternal(file, clean, allTypes, publicTypes, problems) {
    const imports = new Set();
    for (const m of clean.matchAll(/^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)/gm)) {
        imports.add(m[1]);
    }
    const self = moduleOf(file);
    const body = clean.replace(/^\s*import\s+.*$/gm, '');

    for (const [symbol, owners] of allTypes) {
        if (owners.has(self)) continue;                    // 自己模块也有同名类型，按自己的算
        const pub = publicTypes.get(symbol) || new Set();
        // 有一个「已 import 且是 public」的提供方 → 合法
        if ([...owners].some((o) => imports.has(o) && pub.has(o))) continue;
        // 只报「哪里都没 public 过」的情况。若有 public 提供方但没 import，
        // 那是上一条检查（跨模块符号没 import）的事，别重复报。
        if ([...owners].some((o) => pub.has(o))) continue;
        if (!new RegExp(`\\b${symbol}\\b`).test(body)) continue;
        problems.push(
            `${symbol} 是 ${[...owners].join('/')} 的**内部**类型（非 public），跨模块用不了 `
          + `—— 加 import 也没用，得把它挪到共享模块。`);
    }
}

let failures = 0;
let files = 0;

const allFiles = listSwift(SRC);
// 符号索引用整个项目的源码，而不是 lint 目标
const { index: symbolIndex, allTypes, publicTypes } = buildSymbolIndex(listSwift(INDEX_ROOT));

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

    // 4. 字符串/插值/括号的词法体检（能抓到全角括号顶替 ASCII 括号这类问题）
    problems.push(...lexCheck(src));

    // 5. switch case 重名
    findSwitchCaseCollisions(clean, problems);

    // 5. 用了别的模块的符号却没 import
    findMissingImports(file, clean, symbolIndex, problems);

    // 5b. 用了别的模块的**内部**类型（加 import 也救不了，得挪进共享模块）
    findCrossModuleInternal(file, clean, allTypes, publicTypes, problems);

    // 6. 用了系统框架的符号却没 import 对应模块
    findMissingSystemImports(clean, problems);

    // 7. 用了 iOS 16+ 的 API
    findNewerAPIs(clean, problems);

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
