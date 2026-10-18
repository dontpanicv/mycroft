import Foundation

/// A `Menu > Item` path, as `available.menus` lists it and `MENU` takes it.
public struct MenuPath: Equatable, Sendable, CustomStringConvertible {
    public var components: [String]

    public init(_ components: [String]) { self.components = components }

    /// The separator `available.menus` uses.
    public static let separator = " > "

    public var description: String { components.joined(separator: Self.separator) }

    /// Accepts `>`, `›` and `→` between parts, with or without spaces. At least a menu and an item are required.
    public static func parse(_ raw: String) throws(DesktopError) -> MenuPath {
        let parts = raw.split(whereSeparator: { $0 == ">" || $0 == "›" || $0 == "→" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2 else {
            throw .invalid("`menu` must be a path such as \"File > New Note\"; got \"\(raw)\".")
        }
        guard parts.allSatisfy({ !$0.isEmpty }) else {
            throw .invalid("`menu` has an empty part: \"\(raw)\".")
        }
        return MenuPath(parts)
    }

    /// Folds case, the ellipsis ("Save As…" and "Save As..." and "Save As" are one item) and runs of spaces.
    public static func normalize(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["…", "..."] where text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Picks the title matching `component`: an exact match first, then a normalized one. Returns its position.
    public static func match(_ component: String, in titles: [String]) -> Int? {
        if let exact = titles.firstIndex(of: component) { return exact }
        let wanted = normalize(component)
        return titles.firstIndex { normalize($0) == wanted }
    }
}
