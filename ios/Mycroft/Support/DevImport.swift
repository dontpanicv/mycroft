import Foundation
import PiDurableKit

/// Development-only hand-over of credentials from the Mac into a Simulator build.
///
/// `scripts/dev-import.sh` drops files into the app's `Documents/import/` folder:
/// - `codex-auth.json`: `~/.codex/auth.json` (ChatGPT sign-in made by Codex)
/// - `jev.key`: the Jev API key from the Mac's keychain
///
/// On launch they are moved into the keychain and deleted. On a real iPhone, sign in with the device code instead:
/// sharing one refresh token with Codex makes the two apps log each other out.
enum DevImport {
    static var folder: URL { URL.documentsDirectory.appending(path: "import", directoryHint: .isDirectory) }

    static func run(models: Models) async -> [String] {
        var imported: [String] = []
        let fm = FileManager.default
        let codex = folder.appending(path: "codex-auth.json")
        if fm.fileExists(atPath: codex.path) {
            do {
                let credential = try codexCredential(from: Data(contentsOf: codex))
                try await models.setCredential(credential, for: Provider.codex)
                imported.append("ChatGPT sign-in from Codex")
            } catch {
                imported.append("Codex auth.json import failed: \(error.localizedDescription)")
            }
            try? fm.removeItem(at: codex)
        }
        let openAI = folder.appending(path: "openai.key")
        if fm.fileExists(atPath: openAI.path) {
            if let key = try? String(contentsOf: openAI, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                !key.isEmpty
            {
                try? Keychain.write(key, for: Secret.openAI)
                imported.append("OpenAI API key for live voice")
            }
            try? fm.removeItem(at: openAI)
        }
        let jev = folder.appending(path: "jev.key")
        if fm.fileExists(atPath: jev.path) {
            if let key = try? String(contentsOf: jev, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                !key.isEmpty
            {
                try? Keychain.write(key, for: Secret.jev)
                imported.append("Jev API key")
            }
            try? fm.removeItem(at: jev)
        }
        return imported
    }

    /// Converts Codex's `auth.json` (`tokens.access_token`, `refresh_token`, `account_id`) to pi-ai's
    /// `openai-codex` OAuth credential (`access`, `refresh`, `expires` in ms, `accountId`).
    static func codexCredential(from data: Data) throws -> Credential {
        struct AuthFile: Decodable {
            struct Tokens: Decodable {
                let access_token: String
                let refresh_token: String
                let account_id: String?
            }
            let tokens: Tokens
        }
        let file = try JSONDecoder().decode(AuthFile.self, from: data)
        let expires = JWT.expiry(of: file.tokens.access_token) ?? Date().addingTimeInterval(3600)
        let accountId = file.tokens.account_id ?? JWT.chatGPTAccountID(of: file.tokens.access_token)
        guard let accountId else { throw ImportError.missingAccount }
        return Credential(json: [
            "type": "oauth",
            "access": .string(file.tokens.access_token),
            "refresh": .string(file.tokens.refresh_token),
            "expires": .number(expires.timeIntervalSince1970 * 1000),
            "accountId": .string(accountId),
        ])
    }

    enum ImportError: LocalizedError {
        case missingAccount
        var errorDescription: String? { "auth.json has no ChatGPT account id" }
    }
}

/// Just enough JWT reading for token expiry and the ChatGPT account claim.
nonisolated enum JWT {
    static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func expiry(of token: String) -> Date? {
        (claims(of: token)?["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static func chatGPTAccountID(of token: String) -> String? {
        (claims(of: token)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
    }
}
