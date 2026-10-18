import Foundation

/// Pure checks for `OPEN_URL` and `OPEN_FOLDER` inputs, kept out of the backend so they can be tested.
public enum Targets {
    /// `OPEN_URL` opens web pages in the default browser, so only http and https are accepted. A bare host
    /// ("example.com/page") gets https. Other schemes (file:, custom app schemes, javascript:) are refused: they could
    /// open apps or run things, which is not what this operation is for.
    public static func webURL(_ raw: String) throws(DesktopError) -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .invalid("`url` is required for OPEN_URL.") }
        guard !text.contains(where: { $0.isWhitespace }) else { throw .invalid("`url` must not contain spaces: \"\(text)\".") }
        var candidate = text
        if !text.contains("://") {
            if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("."), !text[..<colon].contains("/"),
               Int(text[text.index(after: colon)...].prefix { $0.isNumber }) == nil {
                throw .invalid("OPEN_URL only opens http and https addresses; got \"\(text)\".")
            }
            candidate = "https://" + text
        }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else {
            throw .invalid("`url` is not a valid address: \"\(text)\".")
        }
        guard scheme == "http" || scheme == "https" else {
            throw .invalid("OPEN_URL only opens http and https addresses; got a \(scheme): address.")
        }
        guard let host = url.host, !host.isEmpty else { throw .invalid("`url` has no host: \"\(text)\".") }
        return url
    }

    /// Folder names OPEN_FOLDER accepts on their own, relative to the home folder (Applications is /Applications).
    public static let namedFolders = ["Home", "Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Applications"]

    /// Resolves an OPEN_FOLDER `path`: `~` and `~/...` are under home, a known folder name ("Downloads") is that folder,
    /// an absolute path is itself, and any other relative path is taken relative to home. Existence is checked later.
    public static func folderURL(_ raw: String, home: URL) throws(DesktopError) -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .invalid("`path` is required for OPEN_FOLDER.") }
        if let name = namedFolders.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
            switch name {
            case "Home": return home.standardizedFileURL
            case "Applications": return URL(fileURLWithPath: "/Applications", isDirectory: true)
            default: return home.appendingPathComponent(name, isDirectory: true).standardizedFileURL
            }
        }
        if text == "~" { return home.standardizedFileURL }
        if text.hasPrefix("~/") {
            return home.appendingPathComponent(String(text.dropFirst(2)), isDirectory: true).standardizedFileURL
        }
        if text.hasPrefix("~") { throw .invalid("Only the current user's home (~) is supported: \"\(text)\".") }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text, isDirectory: true).standardizedFileURL }
        return home.appendingPathComponent(text, isDirectory: true).standardizedFileURL
    }
}
