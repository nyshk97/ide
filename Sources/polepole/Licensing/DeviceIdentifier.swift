import CryptoKit
import Foundation
import IOKit

/// デバイス識別子。
///
/// IOPlatformExpertDevice の `IOPlatformUUID` を取り、SHA256 で hex 文字列化して
/// サーバに送る。`IOPlatformUUID` 自体は再 install しても変わらないハードウェア UUID
/// (T2/Apple Silicon は SEP に焼かれる)。
///
/// SHA256 にしてから送るのは、サーバ側で raw UUID を保持しないため
/// (= 漏洩しても他のサービスのデバイス相関に使えない)。32 byte → 64 hex char。
///
/// `deviceName` は表示用 (= ユーザーがスワップ UI で識別するためのラベル) で
/// Host.current().localizedName を使う。
enum DeviceIdentifier {
    /// SHA256 hex (lowercase) の 64 文字。サーバの device_hash と一致するようにする。
    static func deviceHash() -> String {
        guard let uuid = platformUUID() else {
            // 取得できなかった場合は ProcessInfo.hostName など fallback。実機の Mac では
            // 失敗しない想定だが、サンドボックスや CI など特殊環境のための保険。
            let fallback = ProcessInfo.processInfo.hostName + "::fallback"
            Logger.shared.warn("[device] IOPlatformUUID unavailable, using hostname fallback")
            return sha256Hex(of: fallback)
        }
        return sha256Hex(of: uuid)
    }

    /// ユーザー設定のホスト名 (= 「○○ の Mac」)。スワップ UI で「どの Mac か」を見分けるため。
    static func deviceName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// OS バージョン文字列。例: "macOS 14.4.1 (23E224)"。
    static func osVersion() -> String {
        let info = ProcessInfo.processInfo
        return "macOS \(info.operatingSystemVersionString)"
    }

    /// アプリの MARKETING_VERSION (Info.plist の CFBundleShortVersionString)。
    static func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Private

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        return (cf.takeRetainedValue() as? String)
    }

    private static func sha256Hex(of input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
