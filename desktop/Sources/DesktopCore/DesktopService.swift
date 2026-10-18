import Foundation

/// Validates requests, keeps the current observation and dispatches to a backend.
///
/// Only the latest observation is kept: its refs map to backend handles, and a `ui.act` naming any other observation
/// gets `stale`. Calls are serialized by an internal lock, so a socket server may call `handle(line:)` from any thread.
public final class DesktopService: @unchecked Sendable {
    public let backend: DesktopBackend
    /// How long to wait after an action before the second fingerprint. The spec says about 250 ms.
    public var settleDelay: TimeInterval
    /// Receives one line per request (op, outcome, duration). Never sees typed text.
    public var log: (@Sendable (String) -> Void)?

    private struct Current {
        var id: String
        var target: TargetApp
        var elements: [String: SnapshotElement]
    }

    private let lock = NSLock()
    private var current: Current?
    private var counter: Int

    /// `firstObservation` seeds the observation counter. It starts at a random number by default so a phone holding an
    /// id from before a restart cannot hit a new observation with the same id.
    public init(backend: DesktopBackend, settleDelay: TimeInterval = 0.25, firstObservation: Int? = nil) {
        self.backend = backend
        self.settleDelay = settleDelay
        self.counter = (firstObservation ?? Int.random(in: 1...900_000)) - 1
    }

    /// The id of the observation refs currently resolve against.
    public var currentObservation: String? {
        lock.lock()
        defer { lock.unlock() }
        return current?.id
    }

    // MARK: - Lines

    /// Handles one request line and returns one response line (without the newline).
    public func handle(line: Data) -> Data {
        let started = Date()
        let decoder = JSONDecoder()
        let envelope: RequestEnvelope
        do {
            envelope = try decoder.decode(RequestEnvelope.self, from: line)
        } catch {
            log?("request ? -> invalid (not a JSON object)")
            return Wire.failure(id: .null, .invalid("The line is not a JSON object with an `op`: \(Wire.describe(error))."))
        }
        let id = envelope.id ?? .null
        guard let opName = envelope.op else {
            return Wire.failure(id: id, .invalid("`op` is required: one of \(RequestOp.allCases.map(\.rawValue).joined(separator: ", "))."))
        }
        guard let op = RequestOp(rawValue: opName) else {
            log?("request \(opName) -> invalid (unknown op)")
            return Wire.failure(id: id, .invalid("Unknown op \"\(opName)\"; expected one of \(RequestOp.allCases.map(\.rawValue).joined(separator: ", "))."))
        }
        let response: Data
        var outcome = "ok"
        var detail = ""
        do {
            switch op {
            case .ping:
                response = Wire.success(id: id, ping())
            case .observe:
                let request: ObserveRequest
                do { request = try decoder.decode(ObserveRequest.self, from: line) } catch { throw DesktopError.invalid(Wire.describe(error)) }
                let observation = try observe(request)
                detail = " \(observation.observation) \(observation.application) \(observation.elements.count) elements"
                response = Wire.success(id: id, observation)
            case .act:
                let request: ActRequest
                do { request = try decoder.decode(ActRequest.self, from: line) } catch { throw DesktopError.invalid(Wire.describe(error)) }
                detail = " \(request.operation.rawValue)"
                let result = try act(request)
                detail += " changed=\(result.screenChanged)"
                response = Wire.success(id: id, result)
            }
        } catch let error as DesktopError {
            outcome = error.code.rawValue
            response = Wire.failure(id: id, error)
        } catch {
            outcome = ErrorCode.failed.rawValue
            response = Wire.failure(id: id, .failed(error.localizedDescription))
        }
        log?("request \(op.rawValue)\(detail) -> \(outcome) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return response
    }

    // MARK: - Ops

    public func ping() -> PingResult { PingResult(trusted: backend.isTrusted) }

    public func observe(_ request: ObserveRequest) throws(DesktopError) -> Observation {
        lock.lock()
        defer { lock.unlock() }
        guard backend.isTrusted else { throw .notTrusted }
        let maxElements = request.maxElements ?? ObserveRequest.defaultMaxElements
        guard (1...ObserveRequest.maxElementsLimit).contains(maxElements) else {
            throw .invalid("`maxElements` must be between 1 and \(ObserveRequest.maxElementsLimit).")
        }
        let app = request.app?.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot: Snapshot
        do {
            snapshot = try backend.observe(app: app?.isEmpty == false ? app : nil, maxElements: maxElements)
        } catch {
            throw Self.desktopError(error)
        }
        counter += 1
        let id = "o-\(counter)"
        var handles: [String: SnapshotElement] = [:]
        var elements: [UIElement] = []
        for (offset, element) in snapshot.elements.prefix(maxElements).enumerated() {
            let ref = "e\(offset + 1)"
            handles[ref] = element
            elements.append(UIElement(ref: ref, index: offset + 1, role: element.role, label: element.label, value: element.value,
                                      place: element.place, operations: element.operations))
        }
        current = Current(id: id, target: snapshot.target, elements: handles)
        var available = snapshot.available
        available.apps = Array(available.apps.prefix(Available.appsLimit))
        available.menus = Array(available.menus.prefix(Available.menusLimit))
        return Observation(observation: id, application: snapshot.target.name, bundleId: snapshot.target.bundleId,
                           window: snapshot.window, otherWindows: max(0, snapshot.otherWindows), elements: elements,
                           available: available, secureInputActive: snapshot.secureInputActive)
    }

    public func act(_ request: ActRequest) throws(DesktopError) -> ActResult {
        lock.lock()
        defer { lock.unlock() }
        guard backend.isTrusted else { throw .notTrusted }
        let action = try resolve(request)
        let scope: FingerprintScope = switch action {
        case .openApp, .quitApp, .openURL, .openFolder: .frontmost
        case .press(_, let target), .select(_, let target), .click(_, let target), .focus(_, let target),
             .typeText(_, _, let target), .pressKey(_, _, let target), .scroll(_, _, let target), .menu(_, let target): .app(target)
        }
        let before = backend.fingerprint(scope)
        let result: String
        do {
            result = try backend.perform(action)
        } catch {
            throw Self.desktopError(error)
        }
        if settleDelay > 0 { Thread.sleep(forTimeInterval: settleDelay) }
        let after = backend.fingerprint(scope)
        return ActResult(result: result, screenChanged: after.differs(from: before))
    }

    // MARK: - Validation

    static let maxTextLength = 10_000
    static let maxKeyTimes = 100
    static let maxScrollTimes = 50

    /// Checks the fields an operation needs and resolves refs against the current observation.
    func resolve(_ request: ActRequest) throws(DesktopError) -> BackendAction {
        let operation = request.operation
        func required(_ value: String?, _ name: String) throws(DesktopError) -> String {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw .invalid("`\(name)` is required for \(operation.rawValue).")
            }
            return value
        }

        // The observation: required for everything that acts on the observed app, and checked whenever it is given.
        var observed: Current?
        if let id = request.observation {
            guard let current else {
                throw .stale("Observation \(id) is outdated: hands-desktop has no current observation. Call ui.observe again.")
            }
            guard current.id == id else {
                throw .stale("Observation \(id) is outdated; the current one is \(current.id). Call ui.observe again.")
            }
            observed = current
        } else if !operation.isAppLevel {
            throw .invalid("`observation` is required for \(operation.rawValue).")
        }

        func element(required isRequired: Bool) throws(DesktopError) -> SnapshotElement? {
            guard let raw = request.ref?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                if isRequired { throw .invalid("`ref` is required for \(operation.rawValue).") }
                return nil
            }
            guard let observed, let element = observed.elements[raw] else {
                throw .notFound("Unknown ref \(raw) in observation \(observed?.id ?? "?").")
            }
            return element
        }
        func allow(_ element: SnapshotElement, _ accepted: Set<ElementOperation>) throws(DesktopError) {
            guard element.operations.contains(where: accepted.contains) else {
                let supported = element.operations.map { $0.rawValue.uppercased() }.joined(separator: ", ")
                throw .invalid("\(operation.rawValue) is not supported by \(request.ref ?? "") “\(element.label)”; it supports "
                               + (supported.isEmpty ? "CLICK only" : supported) + ".")
            }
        }

        switch operation {
        case .openApp: return .openApp(try required(request.app, "app"))
        case .quitApp: return .quitApp(try required(request.app, "app"))
        case .openURL: return .openURL(try Targets.webURL(try required(request.url, "url")))
        case .openFolder:
            return .openFolder(try Targets.folderURL(try required(request.path, "path"), home: FileManager.default.homeDirectoryForCurrentUser))
        default: break
        }

        guard let observed else { throw .invalid("`observation` is required for \(operation.rawValue).") }
        let target = observed.target
        switch operation {
        case .press:
            let element = try element(required: true)!
            try allow(element, [.press])
            return .press(element, in: target)
        case .select:
            let element = try element(required: true)!
            try allow(element, [.select])
            return .select(element, in: target)
        case .click:
            // A click at the centre is the fallback for any element, so it is accepted on every ref.
            return .click(try element(required: true)!, in: target)
        case .focus:
            let element = try element(required: true)!
            try allow(element, [.focus, .type])
            return .focus(element, in: target)
        case .typeText:
            guard let text = request.text, !text.isEmpty else { throw .invalid("`text` is required for TYPE_TEXT.") }
            guard text.count <= Self.maxTextLength else { throw .invalid("`text` is longer than \(Self.maxTextLength) characters.") }
            let element = try element(required: false)
            if let element { try allow(element, [.type]) }
            return .typeText(text, into: element, in: target)
        case .pressKey:
            let key = try KeyStroke.parse(key: try required(request.key, "key"), modifiers: request.modifiers ?? [])
            let times = request.times ?? 1
            guard (1...Self.maxKeyTimes).contains(times) else { throw .invalid("`times` must be between 1 and \(Self.maxKeyTimes).") }
            return .pressKey(key, times: times, in: target)
        case .scroll:
            guard let direction = request.direction else { throw .invalid("`direction` (up or down) is required for SCROLL.") }
            let times = request.times ?? 1
            guard (1...Self.maxScrollTimes).contains(times) else { throw .invalid("`times` must be between 1 and \(Self.maxScrollTimes).") }
            return .scroll(direction, times: times, in: target)
        case .menu:
            return .menu(try MenuPath.parse(try required(request.menu, "menu")), in: target)
        case .openApp, .quitApp, .openURL, .openFolder:
            preconditionFailure("handled above")
        }
    }

    static func desktopError(_ error: Error) -> DesktopError {
        (error as? DesktopError) ?? .failed(error.localizedDescription)
    }
}
