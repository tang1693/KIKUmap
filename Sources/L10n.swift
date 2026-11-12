import Foundation

/// The languages KIKUmap speaks. The app is written in Chinese and English (`tr(zh, en)`); the rest come from a
/// table (L10nData.swift) keyed by the English text, with "%@" where a value goes. Anything not in the table shows in
/// English (Traditional Chinese: the Simplified text, converted), so a sentence added later is never blank.
enum Lang: String, CaseIterable {
    case zhHans = "zh", zhHant = "zh-Hant", en, ja, ko, es, pt = "pt-BR", de, fr

    /// Its own name, as the language menus list it.
    var name: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .es: return "Español"
        case .pt: return "Português (Brasil)"
        case .de: return "Deutsch"
        case .fr: return "Français"
        }
    }

    /// For dates and numbers.
    var locale: Locale {
        switch self {
        case .zhHans: return Locale(identifier: "zh_CN")
        case .zhHant: return Locale(identifier: "zh_TW")
        case .en: return Locale(identifier: "en_US")
        case .ja: return Locale(identifier: "ja_JP")
        case .ko: return Locale(identifier: "ko_KR")
        case .es: return Locale(identifier: "es_ES")
        case .pt: return Locale(identifier: "pt_BR")
        case .de: return Locale(identifier: "de_DE")
        case .fr: return Locale(identifier: "fr_FR")
        }
    }

    var isChinese: Bool { self == .zhHans || self == .zhHant }

    /// The Mac's first preferred language, if KIKUmap speaks it (else English).
    static var system: Lang {
        let p = (Locale.preferredLanguages.first ?? "en").lowercased()
        if p.hasPrefix("zh") { return p.contains("hant") || p.hasSuffix("-tw") || p.hasSuffix("-hk") || p.hasSuffix("-mo") ? .zhHant : .zhHans }
        for l in [Lang.ja, .ko, .es, .de, .fr] where p.hasPrefix(l.rawValue) { return l }
        if p.hasPrefix("pt") { return .pt }
        return .en
    }

    /// Where its column sits in the table (L10nData's order).
    var column: Int? { L10n.columns.firstIndex(of: rawValue) }
}

/// The English side of `tr(zh, en)`: the text, and its key in the table — the same text with "%@" where each
/// interpolated value goes ("\(n) chats" → "%@ chats"), so one entry serves every number.
struct TrKey: ExpressibleByStringInterpolation {
    let key: String
    let args: [String]
    let value: String

    init(stringLiteral v: String) { key = v; args = []; value = v }
    /// A text that isn't a literal (a table's name, say): looked up as it is.
    init(_ v: String) { key = v; args = []; value = v }
    init(stringInterpolation i: Interp) { key = i.key; args = i.args; value = i.value }
    init(key: String, args: [String], value: String) { self.key = key; self.args = args; self.value = value }

    struct Interp: StringInterpolationProtocol {
        var key = "", value = "", args: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ s: String) { key += s; value += s }
        mutating func appendInterpolation<T>(_ x: T) {
            let s = "\(x)"
            key += "%@"; value += s; args.append(s)
        }
    }
}

enum L10n {
    /// The table's columns, in order (filled by L10nData.swift).
    static let columns = ["zh-Hant", "ja", "ko", "es", "pt-BR", "de", "fr"]

    /// English key → its translations, in `columns` order ("" where there's none yet). Read once, on first use, from
    /// whichever thread asks first (a static let is made safely once).
    static let entries: [String: [String]] = {
        guard let d = L10nData.json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: [String]] else { return [:] }
        return o
    }()

    /// Chinese turned into Traditional characters, kept (it's asked again on every redraw).
    private static let hant = NSCache<NSString, NSString>()
    static func traditional(_ zh: String) -> String {
        if let t = hant.object(forKey: zh as NSString) { return t as String }
        let t = zh.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? zh
        hant.setObject(t as NSString, forKey: zh as NSString)
        return t
    }

    /// The text in `lang`, values put back in ("%@" in turn, or "%2$@" for a given one).
    static func text(_ en: TrKey, zh: String, in lang: Lang) -> String {
        switch lang {
        case .zhHans: return zh
        case .en: return en.value
        default:
            // Traditional Chinese is translated from the Chinese, which can put in other values than the English
            // ("3 个对话" where the English says "3 chats"): then the Chinese, in Traditional characters
            let sameValues = lang != .zhHant || zh.isEmpty || en.args.allSatisfy { zh.contains($0) || zh.contains(traditional($0)) || traditional(zh).contains($0) }
            if sameValues, let c = lang.column, let row = entries[en.key], c < row.count, !row[c].isEmpty { return fill(row[c], en.args) }
            if lang == .zhHant, !zh.isEmpty { return traditional(zh) }
            return en.value
        }
    }

    static func fill(_ t: String, _ args: [String]) -> String {
        guard !args.isEmpty, t.contains("%") else { return t }
        var out = "", i = t.startIndex, next = 0
        while i < t.endIndex {
            if t[i] == "%" {
                let rest = t[t.index(after: i)...]
                if rest.hasPrefix("@") {
                    out += next < args.count ? args[next] : ""
                    next += 1
                    i = t.index(i, offsetBy: 2)
                    continue
                }
                // "%2$@": the second value
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix("$@"), let n = Int(digits), n >= 1 {
                    out += n <= args.count ? args[n - 1] : ""
                    i = t.index(i, offsetBy: 1 + digits.count + 2)
                    continue
                }
            }
            out.append(t[i])
            i = t.index(after: i)
        }
        return out
    }
}
