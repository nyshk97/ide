import CryptoKit
import Foundation

/// アクティベーション署名トークンの検証。
///
/// トークン形式 (backend/src/lib/signing.ts と同じ):
///   `<base64url(payload_json_utf8)>.<base64url(signature_64_bytes)>`
///
/// 検証手順:
/// 1. raw 文字列を "." で split
/// 2. payload と signature をそれぞれ base64url decode
/// 3. payload bytes を JSON parse → TokenPayload
/// 4. `Resources/License/license-pubkey.pem` の Ed25519 公開鍵で signature を検証
///
/// PEM の中身は X.509 SubjectPublicKeyInfo (SPKI) DER で、Ed25519 用は固定 12 byte prefix
/// (`30 2A 30 05 06 03 2B 65 70 03 21 00`) + raw 32 byte 公開鍵。CryptoKit は raw 32 byte を
/// 要求するので、prefix を剥がしてから `Curve25519.Signing.PublicKey(rawRepresentation:)` に渡す。
enum TokenVerifier {
    enum VerifyError: Error {
        case malformedToken
        case malformedPayload
        case signatureInvalid
        case publicKeyMissing
        case publicKeyMalformed
    }

    /// raw token 文字列を検証して payload を返す。失敗時は throw。
    static func verify(_ raw: String) throws -> ActivationToken {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw VerifyError.malformedToken }
        guard let payloadBytes = base64urlDecode(String(parts[0])),
              let signatureBytes = base64urlDecode(String(parts[1]))
        else {
            throw VerifyError.malformedToken
        }

        let pubKey = try loadPublicKey()
        guard pubKey.isValidSignature(signatureBytes, for: payloadBytes) else {
            throw VerifyError.signatureInvalid
        }

        let decoder = JSONDecoder()
        let payload: ActivationToken.TokenPayload
        do {
            payload = try decoder.decode(ActivationToken.TokenPayload.self, from: payloadBytes)
        } catch {
            Logger.shared.warn("[license] token payload decode failed: \(error)")
            throw VerifyError.malformedPayload
        }

        return ActivationToken(raw: raw, payload: payload)
    }

    // MARK: - Public key loading

    private static func loadPublicKey() throws -> Curve25519.Signing.PublicKey {
        // bundle 配置は <Resources>/License/license-pubkey.pem (XcodeGen の type: folder で
        // フォルダ階層を保ったままコピーされる)。subdirectory を省くと見つからないことがあるので
        // 明示する。
        let url: URL
        if let direct = Bundle.main.url(
            forResource: "license-pubkey",
            withExtension: "pem",
            subdirectory: "License"
        ) {
            url = direct
        } else if let flat = Bundle.main.url(
            forResource: "license-pubkey",
            withExtension: "pem"
        ) {
            url = flat
        } else {
            throw VerifyError.publicKeyMissing
        }
        let pem = try String(contentsOf: url, encoding: .utf8)
        let body = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let der = Data(base64Encoded: body) else {
            throw VerifyError.publicKeyMalformed
        }
        // Ed25519 SPKI DER は 44 byte: prefix 12 + raw key 32
        guard der.count == 44 else {
            Logger.shared.warn("[license] unexpected pubkey DER length: \(der.count)")
            throw VerifyError.publicKeyMalformed
        }
        let raw = der.suffix(32)
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        } catch {
            throw VerifyError.publicKeyMalformed
        }
    }

    // MARK: - base64url

    private static func base64urlDecode(_ str: String) -> Data? {
        var s = str.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // padding を補う
        let pad = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: pad)
        return Data(base64Encoded: s)
    }
}
