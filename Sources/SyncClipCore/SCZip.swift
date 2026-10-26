import Foundation
import Compression

/// 手写的最小 zip 读写器（M2/M3 文件同步的传输容器）。
///
/// 为什么不用 ZIPFoundation：仓库铁律是零外部依赖（设计稿 §2），而这里需要的
/// 只是「把几个小文件装进一个 zip / 把服务器来的 zip 解出来」，规格子集很小，
/// 手写比 vendor 一个通用库可控得多。
///
/// 能力边界（刻意收窄，按 ≤50MB 的同步场景设计）：
///   - 读：STORED + DEFLATE；文件名只认 UTF-8（上游 Windows 端 ZipArchive
///     写的就是 UTF-8，互通无虞）
///   - 写：STORE-only。zip 在协议里只是运输容器，服务器与各客户端都按字节流
///     对待；压缩省的流量抵不过 CPU/电量与实现复杂度，超限本来就该拒传
///   - 不做 zip64：单条 ≥4GB 或出现 zip64 扩展字段直接抛错 —— 大小上限卡在
///     15MB（设计稿 §1.5），zip64 在这个场景里只会带来解析风险
///
/// 历史坑：Apple Compression 的 COMPRESSION_ZLIB 处理的是 RFC 1951 raw deflate
/// 流（无 zlib 头/尾），恰好就是 zip entry 的压缩格式 —— 直接喂，不用剥头。
public enum SCZip {

    // MARK: - 结构

    /// central directory 里读出的一条 entry。
    /// 字段全部取自 central 目录而不是 local header：流式写入的 zip（bit 3
    /// data descriptor）local header 里的 crc/size 是 0，central 才是权威值。
    public struct Entry: Equatable {
        public let path: String
        public let isDirectory: Bool
        public let uncompressedSize: Int64
        public let compressedSize: Int64
        public let crc32: UInt32
        /// 0 = STORED，8 = DEFLATE
        public let method: UInt16
        public let localHeaderOffset: Int
    }

    public enum ZipError: Error, CustomStringConvertible {
        case malformed(String)
        case unsupported(String)
        case unsafePath(String)
        case tooLarge(String)
        case checksumMismatch(String)

        public var description: String {
            switch self {
            case .malformed(let why): return "zip 数据损坏：\(why)"
            case .unsupported(let why): return "zip 特性不支持：\(why)"
            case .unsafePath(let path): return "zip 里有不安全的路径：\(path)"
            case .tooLarge(let why): return "zip 内容超过处理上限：\(why)"
            case .checksumMismatch(let path): return "CRC 校验不过：\(path)"
            }
        }
    }

    // MARK: - 读取：central directory

    /// 列出 zip 里的全部 entry（只读 central directory，不碰数据区）。
    public static func entries(of data: Data) throws -> [Entry] {
        let eocd = try locateEOCD(data)
        if eocd.entryCount == 0xFFFF || eocd.cdSize == 0xFFFF_FFFF || eocd.cdOffset == 0xFFFF_FFFF {
            throw ZipError.unsupported("zip64（本实现按 ≤50MB 场景刻意不支持）")
        }
        guard eocd.cdOffset + eocd.cdSize <= eocd.offset else {
            throw ZipError.malformed("central directory 越界")
        }

        let base = data.startIndex
        var out: [Entry] = []
        var p = eocd.cdOffset
        let end = eocd.cdOffset + eocd.cdSize

        for _ in 0..<eocd.entryCount {
            guard p + 46 <= end, u32(data, p) == 0x02014b50 else {
                throw ZipError.malformed("central directory 头签名不对")
            }
            let method = u16(data, p + 10)
            let crc = u32(data, p + 16)
            let csize = u32(data, p + 20)
            let usize = u32(data, p + 24)
            let nameLen = Int(u16(data, p + 28))
            let extraLen = Int(u16(data, p + 30))
            let commentLen = Int(u16(data, p + 32))
            let lho = u32(data, p + 42)
            guard p + 46 + nameLen + extraLen + commentLen <= end else {
                throw ZipError.malformed("central directory 长度字段越界")
            }

            // zip64 判定：4GB 哨兵值，或 extra 字段里出现 zip64 头（0x0001）
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || lho == 0xFFFF_FFFF {
                throw ZipError.unsupported("zip64（本实现按 ≤50MB 场景刻意不支持）")
            }
            try rejectZip64Extra(data, at: p + 46 + nameLen, length: extraLen)

            let nameData = data.subdata(in: base + p + 46 ..< base + p + 46 + nameLen)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ZipError.malformed("文件名不是 UTF-8（entry #\(out.count)）")
            }
            // 空名 entry 属于坏数据；目录与否按「名字以 / 结尾」的 zip 惯例判
            if !name.isEmpty {
                out.append(Entry(path: name,
                                 isDirectory: name.hasSuffix("/"),
                                 uncompressedSize: Int64(usize),
                                 compressedSize: Int64(csize),
                                 crc32: crc,
                                 method: method,
                                 localHeaderOffset: Int(lho)))
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    /// 从尾部向后扫 EOCD（0x06054b50）。
    ///
    /// 为什么要扫而不是按固定偏移取：EOCD 后面可以挂最长 65535 字节的注释，
    /// 不少工具会写。命中后还要验证「注释长度恰好填满到文件尾」才算数，
    /// 否则可能匹配到数据区里恰好长得像签名的字节。
    private static func locateEOCD(_ data: Data) throws
        -> (offset: Int, entryCount: Int, cdSize: Int, cdOffset: Int) {
        let n = data.count
        guard n >= 22 else { throw ZipError.malformed("比 EOCD 还短，不是 zip") }
        let minPos = max(0, n - 22 - 65535)
        var pos = n - 22
        while pos >= minPos {
            if u32(data, pos) == 0x06054b50,
               pos + 22 + Int(u16(data, pos + 20)) == n {
                return (pos,
                        Int(u16(data, pos + 10)),
                        Int(u32(data, pos + 12)),
                        Int(u32(data, pos + 16)))
            }
            pos -= 1
        }
        throw ZipError.malformed("从尾部找不到 EOCD 签名（0x06054b50）")
    }

    /// extra 字段是 (id u16, size u16, bytes) 的序列；只要含 zip64 头就拒收
    private static func rejectZip64Extra(_ d: Data, at offset: Int, length: Int) throws {
        var p = offset
        let end = offset + length
        while p + 4 <= end {
            if u16(d, p) == 0x0001 {
                throw ZipError.unsupported("zip64 扩展字段（本实现按 ≤50MB 场景刻意不支持）")
            }
            p += 4 + Int(u16(d, p + 2))
        }
    }

    // MARK: - 读取：解压到目录

    /// 把 zip 解到目录，返回写入的文件 URL 列表（目录 entry 只建目录、不进列表）。
    ///
    /// 安全闸（对远端来的 zip 是硬要求，设计稿 §2「绝不写坏」）：
    ///   - 路径段出现 `..` 或 `.`、或以 `/` 开头 → 直接抛错整包拒收
    ///   - 每条 entry 解出的字节都要过 CRC32 校验（值取 central 目录的权威 crc）
    ///   - 解压输出有硬上限，防「谎报尺寸的 zip 炸弹」把内存拖爆
    @discardableResult
    public static func extract(_ data: Data,
                               to directory: URL,
                               maxUncompressedBytes: Int = 256 * 1024 * 1024) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = data.startIndex
        var written: [URL] = []

        for entry in try entries(of: data) {
            let segments = try safeSegments(entry.path)
            let target = segments.reduce(directory) { $0.appendingPathComponent($1) }

            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            let lho = entry.localHeaderOffset
            guard lho + 30 <= data.count, u32(data, lho) == 0x04034b50 else {
                throw ZipError.malformed("local header 签名不对（\(entry.path)）")
            }
            // local file header 布局：sig 4B / ver 2B / flags 2B / method 2B /
            // time 2B / date 2B / crc 4B / csize 4B / usize 4B / nameLen 2B@26 / extraLen 2B@28
            let nameLen = Int(u16(data, lho + 26))
            let extraLen = Int(u16(data, lho + 28))
            let dataStart = lho + 30 + nameLen + extraLen
            let csize = Int(entry.compressedSize)
            guard dataStart + csize <= data.count else {
                throw ZipError.malformed("entry 数据区越界（\(entry.path)）")
            }
            if Int(entry.uncompressedSize) > maxUncompressedBytes {
                throw ZipError.tooLarge("\(entry.path) 声明 \(entry.uncompressedSize) 字节")
            }

            let bytes: Data
            switch entry.method {
            case 0:  // STORED
                guard csize == Int(entry.uncompressedSize) else {
                    throw ZipError.malformed("STORED 尺寸对不上（\(entry.path)）")
                }
                bytes = data.subdata(in: base + dataStart ..< base + dataStart + csize)
            case 8:  // DEFLATE
                let src = data.subdata(in: base + dataStart ..< base + dataStart + csize)
                bytes = try inflate(src, uncompressedSize: entry.uncompressedSize,
                                    cap: maxUncompressedBytes)
                guard bytes.count == Int(entry.uncompressedSize) else {
                    throw ZipError.malformed("解压长度与目录声明不符（\(entry.path)）")
                }
            default:
                throw ZipError.unsupported("压缩方法 \(entry.method)（只认 STORED/DEFLATE）")
            }

            // CRC 必验 —— 这是「服务器上的 zip 被改坏/传坏」的最后一道闸
            guard crc32(bytes) == entry.crc32 else {
                throw ZipError.checksumMismatch(entry.path)
            }

            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
            written.append(target)
        }
        return written
    }

    /// entry 名 → 安全的路径段。绝对路径与 `.`/`..` 段直接拒；
    /// `\` 也当分隔符处理（对齐上游：个别工具会写 Windows 风格分隔符）。
    private static func safeSegments(_ raw: String) throws -> [String] {
        if raw.hasPrefix("/") || raw.hasPrefix("\\") || raw.hasPrefix("~") {
            throw ZipError.unsafePath(raw)
        }
        let segments = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if segments.isEmpty { throw ZipError.unsafePath(raw) }
        for s in segments where s == ".." || s == "." {
            throw ZipError.unsafePath(raw)
        }
        return segments
    }

    /// DEFLATE 解压。
    ///
    /// 为什么是「按容量逐档重试」而不是分块喂输入：deflate 是一整条比特流，
    /// 切开来的每段都不是独立流，而 compression_decode_buffer 没有续传接口。
    /// 它在 dst 不够时只会返回 0（分不清「坏了」还是「不够」），所以：
    /// 先按 central 目录给的尺寸分配（绝大多数 zip 是准的），返回 0 就翻倍重试，
    /// 顶到 maxUncompressedBytes 仍不行才判坏 —— 这样既兼容少数 central 尺寸
    /// 写 0 的流式 zip，又封住了谎报尺寸的解压炸弹。
    private static func inflate(_ src: Data, uncompressedSize: Int64, cap: Int) throws -> Data {
        if uncompressedSize == 0 { return Data() }
        var capacity = max(Int(uncompressedSize), 64 * 1024)
        while true {
            if capacity > cap {
                // 到这里 written 一直是 0：要么真是坏数据，要么实际输出远超声明。
                // compression_decode_buffer 分不这两种情况，文案两者都提。
                throw ZipError.tooLarge("解压失败（数据损坏，或输出超过 \(cap) 字节上限）")
            }
            var dst = Data(count: capacity)
            let written: Int = dst.withUnsafeMutableBytes { dstRaw in
                src.withUnsafeBytes { srcRaw in
                    compression_decode_buffer(
                        dstRaw.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        srcRaw.bindMemory(to: UInt8.self).baseAddress!, src.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 {
                dst.removeSubrange(written..<dst.count)
                return dst
            }
            capacity = min(capacity * 2, cap + 1)
        }
    }

    // MARK: - 写入：STORE-only 打包

    /// 把一组文件打成一个 STORE-only zip。
    ///
    /// 布局严格按 PKWare APPNOTE：每条 entry = local header(30B) + 文件名 + 数据，
    /// 全部写完后统一写 central directory + EOCD。crc/size 在 local header 里
    /// 就写全 —— 不用 bit 3 data descriptor，读的一方（包括 Windows 端 ZipArchive）
    /// 直接拿头部字段即可。
    ///
    /// `name` 约定：以 `/` 结尾（或 url 本身是目录）会写成目录 entry；
    /// 与 extract 相同的防穿越清洗在这里对称生效 —— 打包是给远端解的，
    /// 自己就不该产出会让对端为难的名字。
    public static func archive(files: [(name: String, url: URL)], to destination: URL) throws {
        guard !files.isEmpty else { throw ZipError.malformed("没有可打包的文件") }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw ZipError.malformed("创建 \(destination.path) 失败")
        }
        let fh = try FileHandle(forWritingTo: destination)

        var central = Data()
        var count = 0
        var offset = 0
        do {
            for file in files {
                var name = file.name
                let isDirURL = (try? file.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDirURL && !name.hasSuffix("/") { name += "/" }
                _ = try safeSegments(name)   // 打包侧对称防穿越
                let nameBytes = Data(name.utf8)
                guard nameBytes.count <= 0xFFFF else {
                    throw ZipError.tooLarge("文件名超长：\(name)")
                }
                let isDirectory = name.hasSuffix("/")

                // STORE-only 的 local header 必须先知道 crc 和大小才能写，
                // 所以文件得整块进内存 —— 引擎层已经用大小守卫把这条路的
                // 内存上限定在 maxFileMB（15MB 默认），这里不再重复设防
                let content = isDirectory ? Data() : try Data(contentsOf: file.url)
                let crc = crc32(content)
                let dos = dosDateTime(Date())

                try fh.write(contentsOf: localHeader(nameLength: nameBytes.count,
                                                     crc: crc, size: content.count,
                                                     dosTime: dos.time, dosDate: dos.date))
                try fh.write(contentsOf: nameBytes)
                if !content.isEmpty { try fh.write(contentsOf: content) }

                central.append(centralHeader(nameLength: nameBytes.count,
                                              crc: crc, size: content.count,
                                              dosTime: dos.time, dosDate: dos.date,
                                              isDirectory: isDirectory,
                                              localHeaderOffset: offset))
                offset += 30 + nameBytes.count + content.count
                count += 1
                guard count <= 0xFFFF, offset < 0xFFFF_FFFF, central.count < 0xFFFF_FFFF else {
                    throw ZipError.tooLarge("打包结果超过 zip32 容量")
                }
            }
            try fh.write(contentsOf: central)
            try fh.write(contentsOf: eocd(count: count, cdSize: central.count, cdOffset: offset))
            try fh.close()
        } catch {
            // 半截 zip 没有任何价值，删掉免得被当成成品误传
            try? fh.close()
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - 头部构造（全部小端）

    private static func localHeader(nameLength: Int, crc: UInt32, size: Int,
                                    dosTime: UInt16, dosDate: UInt16) -> Data {
        var d = Data()
        d.append(le32Bytes(0x04034b50))
        d.append(le16Bytes(20))            // version needed: 2.0（STORED 够用）
        d.append(le16Bytes(0x0800))        // 通用标志位 11：文件名是 UTF-8
        d.append(le16Bytes(0))             // method 0 = STORED
        d.append(le16Bytes(dosTime))
        d.append(le16Bytes(dosDate))
        d.append(le32Bytes(crc))
        d.append(le32Bytes(UInt32(size)))  // STORED：压缩前后同尺寸
        d.append(le32Bytes(UInt32(size)))
        d.append(le16Bytes(UInt16(nameLength)))
        d.append(le16Bytes(0))             // 无 extra 字段
        return d
    }

    private static func centralHeader(nameLength: Int, crc: UInt32, size: Int,
                                      dosTime: UInt16, dosDate: UInt16,
                                      isDirectory: Bool, localHeaderOffset: Int) -> Data {
        var d = Data()
        d.append(le32Bytes(0x02014b50))
        d.append(le16Bytes(0x0014))        // version made by: 2.0 / FAT
        d.append(le16Bytes(20))            // version needed
        d.append(le16Bytes(0x0800))        // UTF-8 文件名
        d.append(le16Bytes(0))
        d.append(le16Bytes(dosTime))
        d.append(le16Bytes(dosDate))
        d.append(le32Bytes(crc))
        d.append(le32Bytes(UInt32(size)))
        d.append(le32Bytes(UInt32(size)))
        d.append(le16Bytes(UInt16(nameLength)))
        d.append(le16Bytes(0))             // 无 extra
        d.append(le16Bytes(0))             // 无 comment
        d.append(le16Bytes(0))             // disk number start
        d.append(le16Bytes(0))             // internal attributes
        d.append(le32Bytes(isDirectory ? 0x10 : 0x20))  // MS-DOS 目录位/归档位
        d.append(le32Bytes(UInt32(localHeaderOffset)))
        return d
    }

    private static func eocd(count: Int, cdSize: Int, cdOffset: Int) -> Data {
        var d = Data()
        d.append(le32Bytes(0x06054b50))
        d.append(le16Bytes(0))
        d.append(le16Bytes(0))
        d.append(le16Bytes(UInt16(count)))
        d.append(le16Bytes(UInt16(count)))
        d.append(le32Bytes(UInt32(cdSize)))
        d.append(le32Bytes(UInt32(cdOffset)))
        d.append(le16Bytes(0))             // 无注释
        return d
    }

    /// DOS 时间格式（zip 头部惯例）：本地时间、秒粒度减半（2 秒一档）
    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)   // DOS 日期从 1980 起算
        let d = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        let t = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        return (t, d)
    }

    // MARK: - 小端读数（按 startIndex 相对偏移取，兼容切片 Data）

    private static func u16(_ d: Data, _ i: Int) -> UInt16 {
        let b = d.startIndex + i
        return UInt16(d[b]) | (UInt16(d[b + 1]) << 8)
    }

    private static func u32(_ d: Data, _ i: Int) -> UInt32 {
        let b = d.startIndex + i
        return UInt32(d[b]) | (UInt32(d[b + 1]) << 8)
            | (UInt32(d[b + 2]) << 16) | (UInt32(d[b + 3]) << 24)
    }

    private static func le16Bytes(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8)])
    }

    private static func le32Bytes(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
              UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    // MARK: - CRC32（标准查表，zip 用的就是这套）

    /// 反射多项式 0xEDB88320 的经典查表 —— 与 zip/PKWARE 规范一致，
    /// 也和 Windows 端 ZipArchive 写进 central directory 的值对得上。
    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private struct CRC32 {
        private var value: UInt32 = 0xFFFF_FFFF

        mutating func update(_ data: Data) {
            for b in data {
                value = SCZip.crcTable[Int((value ^ UInt32(b)) & 0xFF)] ^ (value >> 8)
            }
        }

        var checksum: UInt32 { value ^ 0xFFFF_FFFF }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c = CRC32()
        c.update(data)
        return c.checksum
    }
}
