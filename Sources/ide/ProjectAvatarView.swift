import SwiftUI

/// プロジェクト一覧で使うアバター（頭文字 + カラー円）。
struct ProjectAvatarView: View {
    let name: String
    let colorKey: String?
    let isMissing: Bool
    var size: CGFloat = 22

    var body: some View {
        let color = ProjectColor.resolve(key: colorKey, for: name).color
        let initial = Self.initial(for: name)
        ZStack {
            Circle()
                .fill(isMissing ? Color.gray.opacity(0.45) : color)
            Text(initial)
                .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    /// 表示名から頭文字 1 文字を取り出す。英字・数字優先で先頭を拾い、
    /// 該当なければ最初の grapheme を使う。空なら「?」。
    static func initial(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        if let alnum = trimmed.first(where: { $0.isLetter || $0.isNumber }) {
            return String(alnum).uppercased()
        }
        return String(trimmed.prefix(1)).uppercased()
    }
}
