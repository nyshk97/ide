import SwiftUI

/// プロジェクトのアバター色パレット。
///
/// `Project.colorKey` には rawValue を保存する。nil なら `automatic(for:)` で
/// プロジェクト名から決定論的に割り当てる。
enum ProjectColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: return Color(red: 0.93, green: 0.34, blue: 0.34)
        case .orange: return Color(red: 0.95, green: 0.58, blue: 0.27)
        case .yellow: return Color(red: 0.92, green: 0.78, blue: 0.31)
        case .green: return Color(red: 0.42, green: 0.78, blue: 0.45)
        case .mint: return Color(red: 0.36, green: 0.82, blue: 0.71)
        case .teal: return Color(red: 0.31, green: 0.69, blue: 0.78)
        case .blue: return Color(red: 0.36, green: 0.60, blue: 0.93)
        case .indigo: return Color(red: 0.45, green: 0.47, blue: 0.86)
        case .purple: return Color(red: 0.66, green: 0.46, blue: 0.88)
        case .pink: return Color(red: 0.92, green: 0.45, blue: 0.69)
        }
    }

    var label: String {
        switch self {
        case .red: return "レッド"
        case .orange: return "オレンジ"
        case .yellow: return "イエロー"
        case .green: return "グリーン"
        case .mint: return "ミント"
        case .teal: return "ティール"
        case .blue: return "ブルー"
        case .indigo: return "インディゴ"
        case .purple: return "パープル"
        case .pink: return "ピンク"
        }
    }

    /// 名前から決定論的にパレットを 1 つ選ぶ（unicode scalar 合計を mod）。
    /// ハッシュ関数は再現性が必要なので Hasher は使わない（ランダム seed が混じる）。
    static func automatic(for name: String) -> ProjectColor {
        let all = ProjectColor.allCases
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return all[abs(sum) % all.count]
    }

    /// 永続化された rawValue から復元。nil/不明値なら automatic にフォールバック。
    static func resolve(key: String?, for name: String) -> ProjectColor {
        if let key, let c = ProjectColor(rawValue: key) { return c }
        return automatic(for: name)
    }
}
