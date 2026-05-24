import Foundation

/// Cloudflare Workers `/v1/license/*` を叩く HTTP クライアント。
///
/// baseURL は環境変数 `POLEPOLE_BACKEND_URL` で上書き可。なければ:
/// - Debug ビルド: `http://127.0.0.1:8787` (wrangler dev のデフォルトポート)
/// - Release ビルド: `https://api.polepole.dev`
///
/// すべて application/json POST で、エラーは `LicenseClientError` に正規化する。
/// 200 系以外は body の `error` フィールドからエラー種別を判別。
struct LicenseClient: Sendable {
    enum LicenseClientError: Error, Equatable, Sendable {
        case network(message: String)
        case invalidCredentials       // 401 invalid_credentials
        case licenseRevoked           // 403 license_revoked
        case licenseRefunded          // 403 license_refunded
        case rateLimited              // 429 rate_limited
        case unknownDevice            // 404 unknown_device
        case deviceNotFound           // 404 device_not_found (deactivate 時)
        case deviceLimit(existing: [ExistingDevice])  // 409 device_limit
        case invalidBody(message: String) // 400 invalid_body
        case server(status: Int, message: String)
    }

    struct ExistingDevice: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let device_name: String?
        let os_version: String?
        let app_version: String?
        let activated_at: Int64
        let last_seen_at: Int64
    }

    struct ActivateResponse: Codable, Sendable {
        let status: String
        let token: String
        struct DeviceInfo: Codable, Sendable {
            let id: String
            let created: Bool
            let activated_at: Int64
        }
        let device: DeviceInfo
    }

    struct VerifyResponse: Codable, Sendable {
        let status: String
        let token: String
        let last_seen_at: Int64
    }

    struct GenericOkResponse: Codable, Sendable {
        let status: String
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let existing_devices: [ExistingDevice]?
    }

    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL ?? Self.defaultBaseURL()
        self.session = session
    }

    static func defaultBaseURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["POLEPOLE_BACKEND_URL"],
           let url = URL(string: raw)
        {
            return url
        }
        #if DEBUG
        return URL(string: "http://127.0.0.1:8787")!
        #else
        // Workers Assets 統合 (Phase 4) で polepole.dev/v1/license/* を 1 Worker で配信。
        // 別 subdomain (api.polepole.dev) は使わない。
        return URL(string: "https://polepole.dev")!
        #endif
    }

    // MARK: - Endpoints

    func activate(
        key: String,
        email: String,
        deviceHash: String,
        deviceName: String,
        osVersion: String,
        appVersion: String
    ) async throws -> ActivateResponse {
        let body: [String: String?] = [
            "key": key,
            "email": email,
            "device_hash": deviceHash,
            "device_name": deviceName,
            "os_version": osVersion,
            "app_version": appVersion,
        ]
        return try await post("/v1/license/activate", body: body)
    }

    func deactivate(
        key: String,
        email: String,
        deviceId: String
    ) async throws -> GenericOkResponse {
        let body: [String: String] = [
            "key": key,
            "email": email,
            "device_id": deviceId,
        ]
        return try await post("/v1/license/deactivate", body: body)
    }

    func verify(
        key: String,
        email: String,
        deviceHash: String,
        osVersion: String,
        appVersion: String
    ) async throws -> VerifyResponse {
        let body: [String: String?] = [
            "key": key,
            "email": email,
            "device_hash": deviceHash,
            "os_version": osVersion,
            "app_version": appVersion,
        ]
        return try await post("/v1/license/verify", body: body)
    }

    func resend(email: String) async throws -> GenericOkResponse {
        let body: [String: String] = ["email": email]
        return try await post("/v1/license/resend", body: body)
    }

    // MARK: - Transport

    private func post<Req: Encodable, Res: Decodable>(_ path: String, body: Req) async throws -> Res {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw LicenseClientError.network(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LicenseClientError.network(message: "no HTTPURLResponse")
        }

        if (200..<300).contains(http.statusCode) {
            do {
                return try JSONDecoder().decode(Res.self, from: data)
            } catch {
                throw LicenseClientError.network(message: "decode failed: \(error)")
            }
        }

        // エラーレスポンスは { error: "..." } を期待
        let parsed = (try? JSONDecoder().decode(ErrorBody.self, from: data))
        let code = parsed?.error ?? "unknown"
        switch (http.statusCode, code) {
        case (401, "invalid_credentials"): throw LicenseClientError.invalidCredentials
        case (403, "license_revoked"): throw LicenseClientError.licenseRevoked
        case (403, "license_refunded"): throw LicenseClientError.licenseRefunded
        case (429, _): throw LicenseClientError.rateLimited
        case (404, "unknown_device"): throw LicenseClientError.unknownDevice
        case (404, "device_not_found"): throw LicenseClientError.deviceNotFound
        case (409, "device_limit"):
            throw LicenseClientError.deviceLimit(existing: parsed?.existing_devices ?? [])
        case (400, "invalid_body"):
            throw LicenseClientError.invalidBody(message: code)
        default:
            throw LicenseClientError.server(status: http.statusCode, message: code)
        }
    }
}
