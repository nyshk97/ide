import SwiftUI

/// DiffViewer の `SyntaxHighlighter` を改名のうえ移植。
/// 名前が一般的だと IDE の他コードと衝突する可能性があるので `DiffSyntaxHighlighter` に。
///
/// `ruleCache` を持つので Swift 6 strict concurrency 下では isolated にする必要がある。
/// SwiftUI View の body から呼ばれる前提なので `@MainActor` で隔離する。
@MainActor
enum DiffSyntaxHighlighter {
    static func highlight(_ code: String, fileName: String) -> AttributedString {
        let lang = detectLanguage(from: fileName)
        var result = AttributedString(code)
        result.foregroundColor = GitHubDark.text

        let compiledRules = cachedRules(for: lang)
        let nsCode = code as NSString

        for rule in compiledRules {
            let matches = rule.regex.matches(in: code, range: NSRange(location: 0, length: nsCode.length))
            for match in matches {
                let matchRange = match.range(at: rule.captureGroup)
                guard let range = Range(matchRange, in: code),
                      let attrRange = Range(range, in: result) else { continue }
                result[attrRange].foregroundColor = rule.color
            }
        }

        return result
    }

    private struct CompiledRule {
        let regex: NSRegularExpression
        let color: Color
        let captureGroup: Int
    }

    private static var ruleCache: [Language: [CompiledRule]] = [:]

    private static func cachedRules(for lang: Language) -> [CompiledRule] {
        if let cached = ruleCache[lang] { return cached }
        let compiled = highlightRules(for: lang).compactMap { rule -> CompiledRule? in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { return nil }
            return CompiledRule(regex: regex, color: rule.color, captureGroup: rule.captureGroup)
        }
        ruleCache[lang] = compiled
        return compiled
    }

    private struct Rule {
        let pattern: String
        let color: Color
        let options: NSRegularExpression.Options
        let captureGroup: Int

        init(_ pattern: String, _ color: Color, options: NSRegularExpression.Options = [], captureGroup: Int = 0) {
            self.pattern = pattern
            self.color = color
            self.options = options
            self.captureGroup = captureGroup
        }
    }

    private enum Language: Hashable {
        case swift, ruby, python, javascript, typescript, go, rust, shell, json, yaml, html, css, sql, java, unknown
    }

    private static func detectLanguage(from fileName: String) -> Language {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "rb", "rake", "gemspec": return .ruby
        case "py": return .python
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "go": return .go
        case "rs": return .rust
        case "sh", "bash", "zsh": return .shell
        case "json": return .json
        case "yml", "yaml": return .yaml
        case "html", "htm", "erb": return .html
        case "css", "scss", "sass": return .css
        case "java": return .java
        case "sql": return .sql
        default:
            let name = (fileName as NSString).lastPathComponent
            if name == "Brewfile" || name == "Gemfile" || name == "Rakefile" { return .ruby }
            if name == "Dockerfile" || name == "Makefile" { return .shell }
            return .unknown
        }
    }

    private static let keyword = Color(red: 255/255, green: 123/255, blue: 114/255)
    private static let string = Color(red: 165/255, green: 214/255, blue: 255/255)
    private static let comment = Color(red: 125/255, green: 133/255, blue: 144/255)
    private static let blue = Color(red: 121/255, green: 192/255, blue: 255/255)
    private static let type = Color(red: 255/255, green: 166/255, blue: 87/255)
    private static let function = Color(red: 210/255, green: 168/255, blue: 255/255)

    private static func highlightRules(for lang: Language) -> [Rule] {
        var rules: [Rule] = []

        switch lang {
        case .swift, .javascript, .typescript, .go, .rust, .css, .java:
            rules.append(Rule(#"//.*$"#, comment))
        case .ruby, .python, .shell, .yaml:
            rules.append(Rule(#"#.*$"#, comment))
        case .html:
            rules.append(Rule(#"<!--.*?-->"#, comment))
        case .sql:
            rules.append(Rule(#"--.*$"#, comment))
        default: break
        }

        rules.append(Rule(#""(?:[^"\\]|\\.)*""#, string))
        rules.append(Rule(#"'(?:[^'\\]|\\.)*'"#, string))
        rules.append(Rule(#"\b\d+\.?\d*\b"#, blue))

        switch lang {
        case .swift:
            rules.append(Rule(#"\b(import|func|var|let|struct|class|enum|protocol|extension|if|else|guard|return|for|in|while|switch|case|default|break|continue|self|Self|nil|true|false|private|public|internal|static|override|init|deinit|throws|throw|try|catch|async|await|some|any|where|typealias|associatedtype|weak|unowned|lazy|mutating|nonmutating|convenience|required|optional|final|open|fileprivate|subscript|defer|repeat|do|is|as|super|willSet|didSet|get|set|inout|operator|precedencegroup|indirect)\b"#, keyword))
            rules.append(Rule(#"\b[A-Z][A-Za-z0-9]*\b"#, type))
            rules.append(Rule(#"@\w+"#, type))
        case .ruby:
            rules.append(Rule(#"\b(def|end|class|module|if|elsif|else|unless|while|until|for|do|begin|rescue|ensure|raise|return|yield|require|require_relative|include|extend|attr_accessor|attr_reader|attr_writer|self|nil|true|false|and|or|not|in|then|when|case|super|puts|print|p)\b"#, keyword))
            rules.append(Rule(#":[a-zA-Z_]\w*"#, blue))
            rules.append(Rule(#"@\w+"#, blue))
        case .python:
            rules.append(Rule(#"\b(def|class|if|elif|else|for|while|return|import|from|as|try|except|finally|raise|with|yield|lambda|pass|break|continue|and|or|not|is|in|None|True|False|self|print|len|range|type|super|async|await)\b"#, keyword))
        case .javascript, .typescript:
            rules.append(Rule(#"\b(const|let|var|function|class|if|else|for|while|return|import|export|from|default|switch|case|break|continue|new|this|throw|try|catch|finally|async|await|yield|typeof|instanceof|in|of|null|undefined|true|false|void|delete|super|extends|implements|interface|type|enum|abstract|static|private|public|protected|readonly|as|is|keyof|infer|never|unknown)\b"#, keyword))
            rules.append(Rule(#"=>"#, keyword))
        case .go:
            rules.append(Rule(#"\b(func|var|const|type|struct|interface|map|chan|package|import|if|else|for|range|switch|case|default|break|continue|return|go|defer|select|fallthrough|nil|true|false|make|len|cap|append|copy|delete|new|panic|recover|print|println|error|string|int|int8|int16|int32|int64|uint|float32|float64|bool|byte|rune)\b"#, keyword))
        case .rust:
            rules.append(Rule(#"\b(fn|let|mut|const|struct|enum|impl|trait|pub|use|mod|crate|self|super|if|else|for|while|loop|match|return|break|continue|move|ref|where|as|in|unsafe|async|await|dyn|type|true|false|Some|None|Ok|Err|Self|Vec|String|Box|Rc|Arc|Option|Result|println|print|format|macro_rules)\b"#, keyword))
            rules.append(Rule(#"\b[A-Z][A-Za-z0-9]*\b"#, type))
        case .shell:
            rules.append(Rule(#"\b(if|then|else|elif|fi|for|while|do|done|case|esac|in|function|return|exit|echo|read|set|unset|export|local|source|alias|cd|ls|rm|cp|mv|mkdir|grep|sed|awk|cat|chmod|chown|sudo|apt|brew|git|curl|wget)\b"#, keyword))
            rules.append(Rule(#"\$[A-Za-z_]\w*"#, blue))
            rules.append(Rule(#"\$\{[^}]+\}"#, blue))
        case .json:
            rules.append(Rule(#"\b(true|false|null)\b"#, keyword))
        case .yaml:
            rules.append(Rule(#"^[A-Za-z_][A-Za-z0-9_]*:"#, keyword))
            rules.append(Rule(#"\b(true|false|null|yes|no)\b"#, blue))
        case .html:
            rules.append(Rule(#"</?[a-zA-Z][a-zA-Z0-9]*"#, keyword))
            rules.append(Rule(#"/?>"#, keyword))
            rules.append(Rule(#"\b[a-zA-Z-]+(?==)"#, type))
        case .css:
            rules.append(Rule(#"[.#]?[a-zA-Z][a-zA-Z0-9_-]*\s*\{"#, keyword))
            rules.append(Rule(#"[a-zA-Z-]+(?=\s*:)"#, type))
        case .java:
            rules.append(Rule(#"\b(abstract|assert|boolean|break|byte|case|catch|char|class|const|continue|default|do|double|else|enum|extends|final|finally|float|for|goto|if|implements|import|instanceof|int|interface|long|native|new|package|private|protected|public|return|short|static|strictfp|super|switch|synchronized|this|throw|throws|transient|try|void|volatile|while|true|false|null)\b"#, keyword))
            rules.append(Rule(#"\b[A-Z][A-Za-z0-9]*\b"#, type))
        case .sql:
            rules.append(Rule(#"\b(?i)(SELECT|FROM|WHERE|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|TABLE|INTO|VALUES|SET|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AND|OR|NOT|NULL|IS|IN|LIKE|BETWEEN|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|AS|DISTINCT|COUNT|SUM|AVG|MIN|MAX|CASE|WHEN|THEN|ELSE|END|INDEX|PRIMARY|KEY|FOREIGN|REFERENCES|CONSTRAINT|DEFAULT|CHECK|UNIQUE|EXISTS|UNION|ALL|ANY|GRANT|REVOKE|BEGIN|COMMIT|ROLLBACK)\b"#, keyword, options: .caseInsensitive))
        default: break
        }

        if lang != .json && lang != .yaml && lang != .unknown {
            rules.append(Rule(#"\b([a-zA-Z_]\w*)\s*\("#, function, captureGroup: 1))
        }

        return rules
    }
}
