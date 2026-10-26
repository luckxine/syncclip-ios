import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 同步协议里会用到的四种图片格式。
///
/// uti 同时给「UTType 常量」和「静态串」两套：UTType 在理论上可能解析失败
/// （极老系统/非常规构建），静态串保证功能不因它断掉。
public enum SCImageFormat: String, CaseIterable {
    case png, jpeg, gif, heic

    public var uti: String {
        switch self {
        case .png: return UTType.png.identifier
        case .jpeg: return UTType.jpeg.identifier
        case .gif: return UTType.gif.identifier
        case .heic: return UTType.heic.identifier
        }
    }

    public var fallbackUTI: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .gif: return "com.compuserve.gif"
        case .heic: return "public.heic"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .gif: return "gif"
        case .heic: return "heic"
        }
    }
}

/// 图片字节流的格式探测与转码（图片同步的地基）。
///
/// 两个决策的出处（v2 设计稿 §4.1）：
///   - 拉取端**写原始字节**进剪贴板，不走 UIImage —— 写 UIImage 会被系统转成 PNG，
///     动图丢帧、字节漂移；
///   - 推送端 HEIC 转 JPEG（质量 0.85），对齐上游 heic→jpg 策略 ——
///     12MP 照片转 PNG 常超过 15MB 链路上限（103 frp 隧道实测，设计稿 §1.5）。
public enum SCImageCodec {

    /// 按 ImageIO 的探测结果识别格式。
    ///
    /// 刻意**不信任扩展名 / dataName**：上游客户端发来的名字固定 .png，
    /// 内容却可能是任何东西；一切都以字节流的真实格式为准。
    public static func sniff(_ data: Data) -> SCImageFormat? {
        guard !data.isEmpty else { return nil }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(src) as String? else { return nil }
        return format(forUTI: uti)
    }

    public static func format(forUTI uti: String) -> SCImageFormat? {
        switch uti {
        case UTType.png.identifier, "public.png": return .png
        case UTType.jpeg.identifier, "public.jpeg": return .jpeg
        case UTType.gif.identifier, "com.compuserve.gif": return .gif
        case UTType.heic.identifier, "public.heic", "public.heif": return .heic
        default: return nil
        }
    }

    /// HEIC → JPEG。失败返回 nil，由调用方按「跳过 + 说明」处理，
    /// 绝不把半截数据写上服务器。
    public static func heicToJPEG(_ data: Data, quality: Double = 0.85) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                  out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 0 else { return nil }
        return out as Data
    }

    /// 上游图片命名约定：Image_yyyy-MM-dd_HH-mm-ss_{random}.{ext}
    ///
    /// 上游固定 .png；扩展名跟随真实格式是 v2 的合法偏差（服务器与其他客户端
    /// 按内容识别，设计稿把它列为 M1 真机验收专项）。
    public static func imageFileName(for format: SCImageFormat, at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let random = String(format: "%06X", UInt32.random(in: 0..<0xFFFFFF))
        return "Image_\(f.string(from: date))_\(random).\(format.fileExtension)"
    }
}
