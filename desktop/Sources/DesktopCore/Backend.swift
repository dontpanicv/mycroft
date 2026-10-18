import Foundation

/// An element as a backend found it. The service gives it a ref; the handle goes back to the backend to act on it.
public protocol ElementHandle {}

/// The app an observation read. Operations other than OPEN_APP, QUIT_APP, OPEN_URL and OPEN_FOLDER act on it.
public struct TargetApp: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var bundleId: String?

    public init(pid: Int32, name: String, bundleId: String?) {
        self.pid = pid
        self.name = name
        self.bundleId = bundleId
    }
}

public struct SnapshotElement {
    public var role: String
    public var label: String
    public var value: String?
    public var place: Place
    public var operations: [ElementOperation]
    public var handle: any ElementHandle

    public init(role: String, label: String, value: String?, place: Place, operations: [ElementOperation], handle: any ElementHandle) {
        self.role = role
        self.label = label
        self.value = value
        self.place = place
        self.operations = operations
        self.handle = handle
    }
}

/// What a backend read for `ui.observe`. Elements are in screen order (top to bottom, then left to right).
public struct Snapshot {
    public var target: TargetApp
    public var window: String?
    public var otherWindows: Int
    public var elements: [SnapshotElement]
    public var available: Available
    public var secureInputActive: Bool

    public init(target: TargetApp, window: String?, otherWindows: Int, elements: [SnapshotElement], available: Available,
                secureInputActive: Bool) {
        self.target = target
        self.window = window
        self.otherWindows = otherWindows
        self.elements = elements
        self.available = available
        self.secureInputActive = secureInputActive
    }
}

/// A validated `ui.act`, resolved against the current observation.
public enum BackendAction {
    case openApp(String)
    case quitApp(String)
    case openURL(URL)
    case openFolder(URL)
    case press(SnapshotElement, in: TargetApp)
    case select(SnapshotElement, in: TargetApp)
    case click(SnapshotElement, in: TargetApp)
    case focus(SnapshotElement, in: TargetApp)
    case typeText(String, into: SnapshotElement?, in: TargetApp)
    case pressKey(KeyStroke, times: Int, in: TargetApp)
    case scroll(ScrollDirection, times: Int, in: TargetApp)
    case menu(MenuPath, in: TargetApp)

    /// A one-line description for logs and tests. Never includes typed text.
    public var summary: String {
        switch self {
        case .openApp(let app): return "OPEN_APP \(app)"
        case .quitApp(let app): return "QUIT_APP \(app)"
        case .openURL(let url): return "OPEN_URL \(url.absoluteString)"
        case .openFolder(let url): return "OPEN_FOLDER \(url.path)"
        case .press(let element, _): return "PRESS \(element.label)"
        case .select(let element, _): return "SELECT \(element.label)"
        case .click(let element, _): return "CLICK \(element.label)"
        case .focus(let element, _): return "FOCUS \(element.label)"
        case .typeText(let text, let element, _): return "TYPE_TEXT \(text.count) characters into \(element?.label ?? "the focused element")"
        case .pressKey(let key, let times, _): return "PRESS_KEY \(key.name) x\(times)"
        case .scroll(let direction, let times, _): return "SCROLL \(direction.rawValue) x\(times)"
        case .menu(let path, _): return "MENU \(path)"
        }
    }
}

/// Where a fingerprint is taken: the app in front (after app-level operations), or the observed app.
public enum FingerprintScope: Equatable, Sendable {
    case frontmost
    case app(TargetApp)
}

/// A captured image of a display, already scaled and encoded.
public struct Screenshot: Equatable, Sendable {
    public var png: Data
    public var width: Int
    public var height: Int

    public init(png: Data, width: Int, height: Int) {
        self.png = png
        self.width = width
        self.height = height
    }
}

/// Everything that touches Accessibility, AppKit, ScreenCaptureKit or the event system. `AXBackend` is the real one;
/// tests use a fake.
public protocol DesktopBackend: AnyObject {
    /// AXIsProcessTrusted().
    var isTrusted: Bool { get }
    /// CGPreflightScreenCaptureAccess(): whether Screen Recording is granted.
    var canRecordScreen: Bool { get }
    /// Captures the main display as PNG, scaled down to at most `maxWidth` pixels wide. Called only when
    /// `canRecordScreen` is true.
    func screenshot(maxWidth: Int) throws -> Screenshot
    /// Reads `app` (a bundle id or name; nil means the frontmost app). Throws `not_found` for an unknown app.
    func observe(app: String?, maxElements: Int) throws -> Snapshot
    func fingerprint(_ scope: FingerprintScope) -> ScreenFingerprint
    /// Performs one action and returns the human-readable result, such as "Pressed “New Note” in Notes".
    func perform(_ action: BackendAction) throws -> String
}
