import Foundation
import SyncClipCore
import SyncClipApp

/// 预读阶段从 NSItemProvider 拿到的东西。
///
/// 分享菜单点开的瞬间系统只给一个"提供者"，字节要自己按类型去要。
/// 预读（loadItem / loadFileRepresentation）在上主控制器里做，这里只管
/// "拿到字节之后怎么上服务器"，两段逻辑分开，各自的失败点才好排。
enum SharePayload {
    case text(String)
    /// 原始字节，格式到上传时才用 SCImageCodec 探测 —— 刻意不信任来源声明的类型。
    case image(Data)
    /// 原名 + 原始字节（文件按"原名单传"的协议约定走附件通道）。
    case file(name: String, data: Data)
}

enum ShareUploadOutcome {
    /// 成功，附给用户看的一句话摘要
    case ok(String)
    /// 失败，附人话原因（不重试就放弃 —— 分享场景用户宁可回主 App 重来）
    case failed(String)
}

enum ShareUploadFlow {

    /// 把预读好的 payload 推上服务器。config 复用主 App 导出的那份设置，
    /// 这样轮询/冲突策略/大小上限与主 App 完全一致，扩展端零配置。
    ///
    /// appex 里网络就是普通的 URLSession（SCClient 内部是 ephemeral session，
    /// 不涉及 appex 禁用的 background session）。
    static func upload(_ payload: SharePayload,
                       settings: SCAppSettings) async -> ShareUploadOutcome {
        do {
            let client = try SCClient(config: settings.toConfig())

            switch payload {
            case .text(let body):
                // 短文本走协议的内联形态（hasData=false），不需要 putFile。
                let entry = SCProfile.text(body)
                try await client.putProfile(entry)
                AppGroupStore.appendHistory(kind: "text", text: body, imageHint: nil)
                return .ok("文本已推送（\(body.count) 字）")

            case .image(let raw):
                guard let format = SCImageCodec.sniff(raw) else {
                    return .failed("认不出图片格式（只认 PNG / JPEG / GIF / HEIC）")
                }
                // HEIC 转 JPEG 对齐主 App 推送策略：12MP 照片直传 PNG 常超链路上限。
                var bytes = raw
                var realFormat = format
                if format == .heic {
                    guard let jpeg = SCImageCodec.heicToJPEG(raw) else {
                        return .failed("HEIC 转 JPEG 失败，这张图推不上去")
                    }
                    bytes = jpeg
                    realFormat = .jpeg
                }
                let fileName = SCImageCodec.imageFileName(for: realFormat)
                // 协议铁律：附件必须先 putFile 再 putProfile，顺序反了服务器 404。
                try await client.putFile(dataName: fileName, content: bytes)
                try await client.putProfile(SCProfile.image(fileName: fileName, content: bytes))
                AppGroupStore.appendHistory(kind: "image",
                                            text: fileName,
                                            imageHint: "\(realFormat.rawValue.uppercased()) \(bytes.count) 字节")
                return .ok("图片已推送（\(fileName)）")

            case .file(let fileName, let fileBytes):
                // 单文件按"原名单传"：text=文件名、hasData=true、dataName=文件名，
                // hash 由 SCProfile.fileEntry 统一算（SHA256(UTF8("文件名|内容hash"))）。
                try await client.putFile(dataName: fileName, content: fileBytes)
                try await client.putProfile(SCProfile.fileEntry(fileName: fileName, content: fileBytes))
                AppGroupStore.appendHistory(kind: "file",
                                            text: fileName,
                                            imageHint: "\(fileBytes.count) 字节")
                return .ok("文件已推送（\(fileName)）")
            }
        } catch {
            return .failed("上传失败：\(error)")
        }
    }
}
