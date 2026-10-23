import PiDurableKit
import SafariServices
import SwiftUI
import UIKit

// The bridge's native bits, its JSON, and the third-party notices.
extension WebBridge {
    // MARK: Native bits

    /// The page's colours, for what is drawn natively: the Live Activity, the recovery screen, Safari.
    func applyTheme(_ args: Args) {
        func hex(_ key: String) -> String? {
            args.string(key).flatMap { Color.components(hex: $0) == nil ? nil : $0 }
        }
        Appearance.shared.apply(.init(accent: hex("accent"), accentSoft: hex("accentSoft"), canvas: hex("canvas"),
                                      raised: hex("raised"), ink: hex("ink"), inkMuted: hex("inkMuted"),
                                      success: hex("success"), danger: hex("danger")))
        webView?.backgroundColor = UIColor(Theme.canvas)
        webView?.scrollView.backgroundColor = UIColor(Theme.canvas)
    }

    func haptic(_ style: String?) {
        switch style {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        default: UIImpactFeedbackGenerator(style: style == "medium" ? .medium : .light).impactOccurred()
        }
    }

    /// A web page inside the app, so Mycroft stays active (iOS would suspend it in Safari).
    func present(_ url: URL) {
        guard url.scheme == "https" || url.scheme == "http", let top = Self.topController() else { return }
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Theme.accentSoft)
        controller.dismissButtonStyle = .done
        safari = controller
        top.present(controller, animated: true)
    }

    static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // MARK: JSON

    /// A page value as a JSON object (tool arguments).
    static func json(_ value: Any?) throws -> JSONObject {
        guard let value, !(value is NSNull) else { return [:] }
        guard JSONSerialization.isValidJSONObject(value),
            case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
        else { throw Failure("Tool arguments must be an object") }
        return object
    }

    static func object(_ value: some Encodable) -> Any? {
        guard let data = try? JSONEncoder.iso.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Sorted keys: feeds compare this text to skip unchanged updates, and a dictionary's order isn't stable.
    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The largest image the page gets, in base64 characters; `show` makes its pictures fit.
    nonisolated static let maxImageBase64 = 600_000

    /// Keeps transcripts light for the page: huge tool outputs are cut, huge images left out.
    static func slim(_ value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            if dictionary["type"] as? String == "image", let data = dictionary["data"] as? String, data.count > maxImageBase64 {
                dictionary["data"] = nil
                dictionary["omitted"] = true
            }
            if dictionary["type"] as? String == "text", let text = dictionary["text"] as? String, text.count > 40_000 {
                dictionary["text"] = String(text.prefix(40_000)) + "\n… (\(text.count - 40_000) more characters)"
            }
            for (key, inner) in dictionary where inner is [Any] || inner is [String: Any] { dictionary[key] = slim(inner) }
            return dictionary
        }
        if let array = value as? [Any] { return array.map(slim) }
        return value
    }

    static let thirdPartyNotices = """
        Mycroft's screen is built with Preact (MIT, © Jason Miller) and htm (Apache-2.0, © Google LLC), \
        bundled as htm's preact/standalone build.

        Mycroft's voice in a conversation is Phonon 31m by Gradium (Apache-2.0), https://huggingface.co/gradium/phonon-31m-en, \
        in FluidInference's Core ML conversion (https://huggingface.co/FluidInference/pocket-tts-coreml), run by FluidAudio.

        Dictation uses Fluid Speech Mini by FluidVoice (CC-BY-4.0), \
        https://huggingface.co/FluidVoice-Labs/fluid-speech-mini-coreml, built on NVIDIA's Parakeet TDT 0.6B v3 \
        (CC-BY-4.0, © NVIDIA Corporation) and Moondream's Parakeet Ultra (CC-BY-4.0, © Moondream), with FluidInference's \
        Parakeet v3 Core ML preprocessor (CC-BY-4.0). Mycroft runs it unchanged (its joint network file renamed for \
        FluidAudio) through FluidAudio (Apache-2.0, © FluidInference). License: https://creativecommons.org/licenses/by/4.0/

        """ + PiDurable.thirdPartyNotices
}

/// The arguments of a call from the page.
struct Args {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }

    func string(_ key: String) -> String? { values[key] as? String }
    func bool(_ key: String) -> Bool? { (values[key] as? NSNumber)?.boolValue }
    func int(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue ?? (values[key] as? String).flatMap(Int.init) }

    func require<T>(_ key: String) throws -> T {
        if T.self == Int.self, let value = int(key) as? T { return value }
        guard let value = values[key] as? T else { throw Failure("Missing \(key)") }
        return value
    }
}
