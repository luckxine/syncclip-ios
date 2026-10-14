import Foundation
import CryptoKit

public enum SCCrypto {

    /// SHA-256 → 大写十六进制（协议规定用大写）
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }
}
