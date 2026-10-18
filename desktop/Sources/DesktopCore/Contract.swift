import Foundation

// The JSON contract of docs/desktop-protocol.md: what `hands` sends over desktop.sock and what comes back.

public let handsDesktopVersion = "0.1.0"

// MARK: - Errors

public enum ErrorCode: String, Codable, Sendable, CaseIterable {
    case notTrusted = "not_trusted"
    case stale
    case notFound = "not_found"
    case invalid
    case failed
    case notSupported = "not_supported"
}

public struct DesktopError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public var code: ErrorCode
    public var message: String

    public init(_ code: ErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }

    private enum CodingKeys: String, CodingKey { case code, message }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(ErrorCode.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
    }

    public static func invalid(_ message: String) -> DesktopError { DesktopError(.invalid, message) }
    public static func failed(_ message: String) -> DesktopError { DesktopError(.failed, message) }
    public static func stale(_ message: String) -> DesktopError { DesktopError(.stale, message) }
    public static func notFound(_ message: String) -> DesktopError { DesktopError(.notFound, message) }

    public static let notTrustedMessage = "hands-desktop does not have Accessibility permission. Open System Settings > "
        + "Privacy & Security > Accessibility and turn on hands-desktop (or run `hands-desktop request-permission` "
        + "in the logged-in session), then try again."
    public static let notTrusted = DesktopError(.notTrusted, notTrustedMessage)
}

// MARK: - Requests

/// Request ops understood on the socket. `ping` is an addition to the spec so `hands` can check reachability and trust.
public enum RequestOp: String, Sendable, CaseIterable {
    case observe = "ui.observe"
    case act = "ui.act"
    case ping
}

public struct ObserveRequest: Codable, Equatable, Sendable {
    /// A bundle id or an app name. Without it, the frontmost app is read.
    public var app: String?
    /// Defaults to 150.
    public var maxElements: Int?

    public init(app: String? = nil, maxElements: Int? = nil) {
        self.app = app
        self.maxElements = maxElements
    }

    public static let defaultMaxElements = 150
    public static let maxElementsLimit = 1000
}

public enum ActOperation: String, Codable, Sendable, CaseIterable {
    case openApp = "OPEN_APP"
    case quitApp = "QUIT_APP"
    case openURL = "OPEN_URL"
    case openFolder = "OPEN_FOLDER"
    case press = "PRESS"
    case select = "SELECT"
    case click = "CLICK"
    case focus = "FOCUS"
    case typeText = "TYPE_TEXT"
    case pressKey = "PRESS_KEY"
    case scroll = "SCROLL"
    case menu = "MENU"

    /// Operations about apps, URLs and folders, rather than the observed window.
    public var isAppLevel: Bool { [.openApp, .quitApp, .openURL, .openFolder].contains(self) }
    /// Operations whose target is an element `ref`.
    public var takesRef: Bool { [.press, .select, .click, .focus, .typeText].contains(self) }
}

public enum ScrollDirection: String, Codable, Sendable, CaseIterable {
    case up, down
}

public struct ActRequest: Codable, Equatable, Sendable {
    public var observation: String?
    public var operation: ActOperation
    public var ref: String?
    public var app: String?
    public var url: String?
    public var path: String?
    public var text: String?
    public var key: String?
    public var modifiers: [String]?
    public var times: Int?
    public var direction: ScrollDirection?
    public var menu: String?

    public init(observation: String? = nil, operation: ActOperation, ref: String? = nil, app: String? = nil,
                url: String? = nil, path: String? = nil, text: String? = nil, key: String? = nil,
                modifiers: [String]? = nil, times: Int? = nil, direction: ScrollDirection? = nil, menu: String? = nil) {
        self.observation = observation
        self.operation = operation
        self.ref = ref
        self.app = app
        self.url = url
        self.path = path
        self.text = text
        self.key = key
        self.modifiers = modifiers
        self.times = times
        self.direction = direction
        self.menu = menu
    }
}

// MARK: - Results

public enum Place: String, Codable, Sendable, CaseIterable {
    case toolbar, sidebar, content, dialog, menu
}

public enum ElementOperation: String, Codable, Sendable, CaseIterable {
    case press, select, click, focus, type
}

public struct UIElement: Codable, Equatable, Sendable {
    public var ref: String
    public var index: Int
    public var role: String
    public var label: String
    public var value: String?
    public var place: Place
    public var operations: [ElementOperation]

    public init(ref: String, index: Int, role: String, label: String, value: String?, place: Place, operations: [ElementOperation]) {
        self.ref = ref
        self.index = index
        self.role = role
        self.label = label
        self.value = value
        self.place = place
        self.operations = operations
    }

    private enum CodingKeys: String, CodingKey { case ref, index, role, label, value, place, operations }

    // `value` is written as an explicit null, as in the spec.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(index, forKey: .index)
        try container.encode(role, forKey: .role)
        try container.encode(label, forKey: .label)
        try container.encode(value, forKey: .value)
        try container.encode(place, forKey: .place)
        try container.encode(operations, forKey: .operations)
    }
}

public struct Available: Codable, Equatable, Sendable {
    public var apps: [String]
    public var folders: [String]
    public var sites: [String]
    public var menus: [String]

    public init(apps: [String] = [], folders: [String] = [], sites: [String] = [], menus: [String] = []) {
        self.apps = apps
        self.folders = folders
        self.sites = sites
        self.menus = menus
    }

    public static let appsLimit = 200
    public static let menusLimit = 300
}

public struct Observation: Codable, Equatable, Sendable {
    public var observation: String
    public var application: String
    public var bundleId: String?
    public var window: String?
    public var otherWindows: Int
    public var elements: [UIElement]
    public var available: Available
    public var secureInputActive: Bool

    public init(observation: String, application: String, bundleId: String?, window: String?, otherWindows: Int,
                elements: [UIElement], available: Available, secureInputActive: Bool) {
        self.observation = observation
        self.application = application
        self.bundleId = bundleId
        self.window = window
        self.otherWindows = otherWindows
        self.elements = elements
        self.available = available
        self.secureInputActive = secureInputActive
    }

    private enum CodingKeys: String, CodingKey {
        case observation, application, bundleId, window, otherWindows, elements, available, secureInputActive
    }

    // `bundleId` and `window` are written as explicit nulls when absent.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(observation, forKey: .observation)
        try container.encode(application, forKey: .application)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encode(window, forKey: .window)
        try container.encode(otherWindows, forKey: .otherWindows)
        try container.encode(elements, forKey: .elements)
        try container.encode(available, forKey: .available)
        try container.encode(secureInputActive, forKey: .secureInputActive)
    }
}

public struct ActResult: Codable, Equatable, Sendable {
    public var result: String
    public var screenChanged: Bool

    public init(result: String, screenChanged: Bool) {
        self.result = result
        self.screenChanged = screenChanged
    }
}

public struct PingResult: Codable, Equatable, Sendable {
    public var trusted: Bool
    public var version: String

    public init(trusted: Bool, version: String = handsDesktopVersion) {
        self.trusted = trusted
        self.version = version
    }
}
