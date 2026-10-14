import Foundation

/// 读自己二进制里内嵌的 entitlement。
///
/// 为什么需要它：TrollStore 会把 IPA 里的 entitlement 原样保留并被系统承认，
/// 但「我以为签上了」和「实际签上了」是两件事。这个工具直接把签名段里的
/// entitlement plist 抠出来，所以在 App 里一眼就能看到这块地基有没有打好，
/// 不用去设备上找 ldid。
///
/// 解析路径：
///   Mach-O 头 → LC_CODE_SIGNATURE(0x1d) → linkedit_data_command → SuperBlob(0xfade0cc0)
///   → 索引里 type==5(CSSLOT_ENTITLEMENTS) → blob(0xfade7171) → XML plist
public enum SCEntitlementInspector {

    public enum InspectError: Error, CustomStringConvertible {
        case cannotRead(String)
        case notMachO
        case fatBinaryUnsupported
        case noCodeSignature
        case malformed(String)

        public var description: String {
            switch self {
            case .cannotRead(let p): return "读不到文件：\(p)"
            case .notMachO: return "不是 Mach-O 文件"
            case .fatBinaryUnsupported: return "是 FAT 胖二进制（暂不支持）"
            case .noCodeSignature: return "找不到 LC_CODE_SIGNATURE：这个二进制根本没有签名段"
            case .malformed(let why): return "签名段结构异常：\(why)"
            }
        }
    }

    private static let lcCodeSignature: UInt32 = 0x1d
    private static let superBlobMagic: UInt32 = 0xfade_0cc0
    private static let entitlementsBlobMagic: UInt32 = 0xfade_7171
    private static let csslotEntitlements: UInt32 = 5

    /// 读指定二进制内嵌的 entitlement 字典
    public static func entitlements(atPath path: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw InspectError.cannotRead(path)
        }
        return try entitlements(in: data)
    }

    /// 直接从内存里的 Mach-O 数据解析（桌面自测用）
    public static func entitlements(in data: Data) throws -> [String: Any] {
        guard data.count > 32 else { throw InspectError.notMachO }

        // FAT：magic 0xcafebabe / 0xbebafeca
        let magicLE = data.readU32(0)
        if magicLE == 0xcafe_babe || magicLE == 0xbeba_feca || magicLE == 0xcafe_babf {
            throw InspectError.fatBinaryUnsupported
        }

        // 只接受 64 位小端（0xfeedfacf 以 LE 读出来就是它自己）
        guard magicLE == 0xfeed_facf else { throw InspectError.notMachO }

        let ncmds = data.readU32(16)
        var offset = 32

        var codeSigOffset: Int?
        var codeSigSize: Int?

        for _ in 0..<ncmds {
            guard offset + 8 <= data.count else {
                throw InspectError.malformed("load command 越界")
            }
            let cmd = data.readU32(offset)
            let cmdsize = Int(data.readU32(offset + 4))
            guard cmdsize >= 8, offset + cmdsize <= data.count else {
                throw InspectError.malformed("load command 长度非法")
            }
            if cmd == lcCodeSignature {
                guard cmdsize >= 16 else { throw InspectError.malformed("linkedit_data_command 过短") }
                codeSigOffset = Int(data.readU32(offset + 8))
                codeSigSize = Int(data.readU32(offset + 12))
            }
            offset += cmdsize
        }

        guard let sigOff = codeSigOffset, let sigLen = codeSigSize else {
            throw InspectError.noCodeSignature
        }
        guard sigOff >= 0, sigLen > 0, sigOff + sigLen <= data.count else {
            throw InspectError.malformed("签名段越界（off=\(sigOff) len=\(sigLen) filesize=\(data.count)）")
        }

        // ---- SuperBlob ----
        let blobStart = sigOff
        let superMagic = data.readU32BE(blobStart)
        guard superMagic == superBlobMagic else {
            throw InspectError.malformed(String(format: "SuperBlob magic 不对：0x%08x", superMagic))
        }
        let count = Int(data.readU32BE(blobStart + 8))
        guard count >= 0, count < 64 else { throw InspectError.malformed("索引项数量异常：\(count)") }

        for i in 0..<count {
            let entry = blobStart + 12 + i * 8
            guard entry + 8 <= data.count else { throw InspectError.malformed("索引越界") }
            let type = data.readU32BE(entry)
            let rel = Int(data.readU32BE(entry + 4))
            guard type == csslotEntitlements else { continue }

            let entStart = blobStart + rel
            guard entStart + 8 <= data.count else { throw InspectError.malformed("entitlement blob 越界") }
            let entMagic = data.readU32BE(entStart)
            guard entMagic == entitlementsBlobMagic else {
                throw InspectError.malformed(String(format: "entitlement blob magic 不对：0x%08x", entMagic))
            }
            let entLen = Int(data.readU32BE(entStart + 4))
            guard entLen >= 8, entStart + entLen <= data.count else {
                throw InspectError.malformed("entitlement 内容长度非法")
            }

            let xml = data.subdata(in: (entStart + 8)..<(entStart + entLen))
            guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil),
                  let dict = plist as? [String: Any] else {
                throw InspectError.malformed("entitlement 不是合法 plist")
            }
            return dict
        }

        throw InspectError.noCodeSignature
    }

    /// 只看 key 列表，方便 UI 展示
    public static func entitlementKeys(atPath path: String) -> [String] {
        guard let dict = try? entitlements(atPath: path) else { return [] }
        return dict.keys.sorted()
    }
}

// MARK: - 大小端读取helper

extension Data {
    fileprivate func readU32(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= count else { return 0 }
        return UInt32(self[startIndex + at])
            | (UInt32(self[startIndex + at + 1]) << 8)
            | (UInt32(self[startIndex + at + 2]) << 16)
            | (UInt32(self[startIndex + at + 3]) << 24)
    }

    /// 大端：代码签名里的所有结构（SuperBlob / blob）都是网络字节序
    fileprivate func readU32BE(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= count else { return 0 }
        return (UInt32(self[startIndex + at]) << 24)
            | (UInt32(self[startIndex + at + 1]) << 16)
            | (UInt32(self[startIndex + at + 2]) << 8)
            | UInt32(self[startIndex + at + 3])
    }
}
