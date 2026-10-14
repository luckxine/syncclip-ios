import Foundation
import CryptoKit

/// AWS Signature Version 4 签名。
///
/// 拆成纯函数是为了能**在设备上自检**：AWS 官方文档给出了完整的测试向量
/// （access key `AKIDEXAMPLE` / secret `wJalr…EXAMPLEKEY` / region `us-east-1` /
/// service `iam` / dateStamp `20150830`），期望的签名密钥是固定的十六进制串。
/// 诊断页里会拿它跑一遍 deriveSigningKey —— 签名算法算错的话，在用 S3 之前就看得见，
/// 而不是等到同步失败去猜是网络还是签名问题。
///
/// 与上游 Xposed 模块的 S3Client 一致，用 `UNSIGNED-PAYLOAD`：
/// 大文件不必为了算 hash 而二次读取整份内容。
public enum SCSigV4 {

    public static let algorithm = "AWS4-HMAC-SHA256"
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    // MARK: - 基础原语

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hmacSHA256(key: Data, _ message: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8),
                                                  using: SymmetricKey(data: key))
        return Data(mac)
    }

    public static func hmacSHA256Hex(key: Data, _ message: String) -> String {
        hmacSHA256(key: key, message).map { String(format: "%02x", $0) }.joined()
    }

    /// 派生签名密钥：kSecret → kDate → kRegion → kService → kSigning
    public static func deriveSigningKey(secretAccessKey: String,
                                        dateStamp: String,
                                        region: String,
                                        service: String = "s3") -> Data {
        let kSecret = Data(("AWS4" + secretAccessKey).utf8)
        let kDate = hmacSHA256(key: kSecret, dateStamp)
        let kRegion = hmacSHA256(key: kDate, region)
        let kService = hmacSHA256(key: kRegion, service)
        return hmacSHA256(key: kService, "aws4_request")
    }

    // MARK: - URI 编码

    /// AWS 的 UriEncode：只有 `A-Za-z0-9-_.~` 不编码，其余一律百分号编码。
    /// - Parameter encodeSlash: false 时保留 `/`（用于对象 key 的路径）
    ///
    /// 注意不要用 `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)`：
    /// 它会把 `+`、`@`、`:` 等留给上层解释，而 SigV4 要求这些也必须编码，
    /// 否则签名和服务器算出来的不一致。
    public static func uriEncode(_ input: String, encodeSlash: Bool) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        var out = ""
        out.reserveCapacity(input.utf8.count)
        for byte in input.utf8 {
            let scalar = Character(UnicodeScalar(byte))
            if unreserved.contains(scalar) {
                out.append(scalar)
            } else if byte == UInt8(ascii: "/") && !encodeSlash {
                out.append("/")
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    // MARK: - 规范化

    /// 规范化查询串：按参数名（再按值）排序，键值都做 UriEncode。
    /// 入参是**未编码**的键值对，避免二次编码。
    public static func canonicalQueryString(_ params: [(String, String)]) -> String {
        params
            .map { (uriEncode($0.0, encodeSlash: true), uriEncode($0.1, encodeSlash: true)) }
            .sorted { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// 规范化头部：键名小写、按字典序排列，值去掉首尾空白
    public static func canonicalHeaders(_ headers: [String: String]) -> (canonical: String, signed: String) {
        let sorted = headers
            .map { (key: $0.key.lowercased(), value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .sorted { $0.key < $1.key }
        let canonical = sorted.map { "\($0.key):\($0.value)\n" }.joined()
        let signed = sorted.map { $0.key }.joined(separator: ";")
        return (canonical, signed)
    }

    /// 拼出 CanonicalRequest（六行）
    public static func canonicalRequest(method: String,
                                        canonicalPath: String,
                                        query: String,
                                        canonicalHeaders: String,
                                        signedHeaders: String,
                                        payloadHash: String) -> String {
        [method, canonicalPath, query, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
    }

    /// 拼出 StringToSign（四行）
    public static func stringToSign(amzDate: String,
                                    credentialScope: String,
                                    canonicalRequestHash: String) -> String {
        [algorithm, amzDate, credentialScope, canonicalRequestHash].joined(separator: "\n")
    }

    public static func credentialScope(dateStamp: String, region: String, service: String = "s3") -> String {
        "\(dateStamp)/\(region)/\(service)/aws4_request"
    }

    public static func authorizationHeader(accessKeyID: String,
                                           credentialScope: String,
                                           signedHeaders: String,
                                           signature: String) -> String {
        "\(algorithm) Credential=\(accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    // MARK: - 时间戳

    /// 20150830T123600Z
    public static func amzDate(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// 20150830
    public static func dateStamp(_ date: Date = Date()) -> String {
        String(amzDate(date).prefix(8))
    }

    // MARK: - 自检

    public struct SelfTestResult {
        public var passed: Bool
        public var detail: String
    }

    /// 用 AWS 官方测试向量验证签名密钥派生。
    /// 这是 App 里能直接跑的真实验证：算法写错的话这里就会失败。
    public static func selfTest() -> SelfTestResult {
        let expected = "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9"
        let actual = deriveSigningKey(secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                      dateStamp: "20150830",
                                      region: "us-east-1",
                                      service: "iam")
            .map { String(format: "%02x", $0) }.joined()

        // 顺带验一下 uriEncode 的两个易错点
        let slashKept = uriEncode("file/a b+c~d.txt", encodeSlash: false) == "file/a%20b%2Bc~d.txt"
        let slashEncoded = uriEncode("a/b", encodeSlash: true) == "a%2Fb"
        // 以及规范化查询串会按参数名排序
        let querySorted = canonicalQueryString([("prefix", "a"), ("list-type", "2"), ("max-keys", "1")])
            == "list-type=2&max-keys=1&prefix=a"

        let problems: [String] = [
            actual == expected ? nil : "签名密钥不对：期望 \(expected.prefix(16))…，实际 \(actual.prefix(16))…",
            slashKept ? nil : "uriEncode 对空格/+ 的处理不对（或把 ~ 编码了）",
            slashEncoded ? nil : "uriEncode 的 encodeSlash 分支不对",
            querySorted ? nil : "规范化查询串没有按参数名排序",
        ].compactMap { $0 }

        return SelfTestResult(passed: problems.isEmpty,
                              detail: problems.isEmpty
                                  ? "SigV4 签名算法通过 AWS 官方测试向量校验"
                                  : problems.joined(separator: "；"))
    }
}
