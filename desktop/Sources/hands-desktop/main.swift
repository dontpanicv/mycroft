import DesktopCore
import Foundation

let usage = """
hands-desktop \(handsDesktopVersion) (Mycroft Hands.app): the macOS desktop-control helper of Mycroft's `hands`.

Usage:
  hands-desktop serve [--socket PATH]         Serve ui.observe / ui.act / ui.screenshot on a Unix socket
                                              (newline-delimited JSON). Default: $HANDS_STATE_DIR/desktop.sock,
                                              else ~/Library/Application Support/hands/desktop.sock
  hands-desktop observe [--app X] [--max N]   Print one observation as JSON.
  hands-desktop act '<json>' [--app X]        Run one ui.act and print the result. The observation is taken fresh
                                              (of --app or the frontmost app), so refs match a preceding `observe`
                                              only if the screen has not changed.
  hands-desktop screenshot --out FILE [--max-width N]
                                              Capture the main display as PNG (needs Screen Recording).
  hands-desktop permissions [--json] [--request] [--wait SECONDS]
                                              Report Accessibility and Screen Recording (exit 0 when both are
                                              granted). --request shows macOS's prompts and the System Settings
                                              panes, then waits (default 300 s) until both are granted.
  hands-desktop --request-permissions [--wait SECONDS]
                                              The request flow, run inside the app: what
                                              `open -n "Mycroft Hands.app" --args --request-permissions` runs.
  hands-desktop doctor                        Report the permissions and how to grant them.
  hands-desktop --version | help

macOS asks for, and grants, both permissions to the app that started a process: "Mycroft Hands" when launchd
starts it (the LaunchAgent, or `open`), but the terminal app when you run it from a shell. So, from a shell,
`permissions` asks the running helper, and `permissions --request` opens the app to ask.
"""

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("hands-desktop: \(message)\n".utf8))
    exit(code)
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

/// Option values after the subcommand: `--name value`. Positional arguments are returned in order.
func parseOptions(_ arguments: ArraySlice<String>, allowed: Set<String>) -> (options: [String: String], positional: [String]) {
    var options: [String: String] = [:]
    var positional: [String] = []
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        if argument.hasPrefix("--") {
            let name = String(argument.dropFirst(2))
            guard allowed.contains(name) else { fail("unknown option \(argument)\n\n\(usage)") }
            guard let value = iterator.next() else { fail("\(argument) needs a value") }
            options[name] = value
        } else {
            positional.append(argument)
        }
    }
    return (options, positional)
}

/// Runs `work` off the main thread while the main run loop spins, so NSWorkspace's state and callbacks stay live.
func runOffMain(_ work: @escaping @Sendable () -> Int32) -> Never {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var status: Int32 = 0
    Thread.detachNewThread {
        status = work()
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(status)
}

/// Pretty-prints one response line and returns the exit status (0 when ok).
func printResponse(_ line: Data) -> Int32 {
    let object = try? JSONSerialization.jsonObject(with: line)
    if let object, let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
        FileHandle.standardOutput.write(pretty + Data("\n".utf8))
    } else {
        FileHandle.standardOutput.write(line + Data("\n".utf8))
    }
    return (object as? [String: Any])?["ok"] as? Bool == true ? 0 : 1
}

func requestLine(_ fields: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
}

/// Splits flags (no value) from options (`--name value`) and positional arguments.
func parseFlags(_ arguments: ArraySlice<String>, flags: Set<String>, options allowed: Set<String>)
    -> (flags: Set<String>, options: [String: String], positional: [String]) {
    var found: Set<String> = []
    var options: [String: String] = [:]
    var positional: [String] = []
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        guard argument.hasPrefix("--") else { positional.append(argument); continue }
        let name = String(argument.dropFirst(2))
        if flags.contains(name) {
            found.insert(name)
        } else if allowed.contains(name) {
            guard let value = iterator.next() else { fail("\(argument) needs a value") }
            options[name] = value
        } else {
            fail("unknown option \(argument)\n\n\(usage)")
        }
    }
    return (found, options, positional)
}

let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
/// The .app this binary runs from, if any.
let appBundlePath: String? = Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath : nil
/// launchd started this process (the LaunchAgent, or `open`), so TCC answers for Mycroft Hands itself.
let startedByLaunchd = getppid() == 1
let defaultPermissionWait: TimeInterval = 300

func waitOption(_ options: [String: String]) -> TimeInterval {
    guard let raw = options["wait"] else { return defaultPermissionWait }
    guard let value = TimeInterval(raw), value >= 0, value <= 3600 else { fail("--wait needs a number of seconds (0-3600)") }
    return value
}

func describe(_ state: PermissionState) -> String {
    "accessibility:     \(state.accessibility ? "granted" : "NOT granted")\n"
        + "screen recording:  \(state.screenRecording ? "granted" : "NOT granted")"
}

func printReport(_ report: PermissionsReport, json: Bool) {
    if json {
        FileHandle.standardOutput.write(report.json() + Data("\n".utf8))
    } else {
        print(describe(report.state))
        if report.source == "self", !startedByLaunchd, appBundlePath == nil {
            print("(answered for this process; started from a terminal, macOS checks the terminal app instead)")
        }
    }
}

/// Restarts the serving helper so it picks up a new Screen Recording grant, which a process only sees after a restart.
/// Done when the grants changed, or when the helper's ping disagrees with `state` (macOS's "Quit & Reopen" may have
/// ended an earlier flow before it got here). Skipped when this process is that LaunchAgent.
func restartServingHelper(after state: PermissionState, before: PermissionState) {
    guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != handsDesktopBundleId else { return }
    let helper = SocketClient.ping(path: Paths.defaultSocket())
    let disagrees = helper.map { $0.trusted != state.accessibility || $0.screenRecording != state.screenRecording } ?? false
    guard state != before || disagrees else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(handsDesktopBundleId)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

/// The request flow in this process. Prompts name this process's responsible app.
func requestInProcess(wait: TimeInterval, json: Bool) -> Never {
    if appBundlePath == nil, !startedByLaunchd {
        log("warning: not running inside Mycroft Hands.app, so macOS asks for (and grants) the app that started this process")
    }
    runOffMain {
        let system = SystemPermissions(freshCheck: [executablePath, "permissions", "--json", "--in-process"])
        let before = SystemPermissions.inProcess()
        let state = PermissionFlow.request(system, wait: wait, log: { log("permissions: \($0)") })
        restartServingHelper(after: state, before: before)
        printReport(PermissionsReport(state: state, bundleId: Bundle.main.bundleIdentifier, executable: executablePath,
                                      source: "self"), json: json)
        if !state.allGranted, !json {
            print("Approve \"Mycroft Hands\" in System Settings > Privacy & Security > Accessibility and > Screen & System Audio Recording.")
        }
        return state.allGranted ? 0 : 1
    }
}

/// `permissions --request`: in this process when launchd started it (or outside the app, where there is no choice),
/// otherwise through the app.
func request(wait: TimeInterval, json: Bool, inProcess: Bool) -> Never {
    if inProcess || appBundlePath == nil { requestInProcess(wait: wait, json: json) }
    requestThroughApp(appBundlePath!, wait: wait, json: json)
}

/// From a terminal: open the app to ask, then follow the helper's answers.
func requestThroughApp(_ app: String, wait: TimeInterval, json: Bool) -> Never {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-n", "-g", app, "--args", "--request-permissions", "--wait", String(Int(wait))]
    do {
        try open.run()
        open.waitUntilExit()
    } catch {
        fail("could not open \(app): \(error.localizedDescription)", code: 1)
    }
    guard open.terminationStatus == 0 else { fail("could not open \(app) (open exited with \(open.terminationStatus))", code: 1) }
    if !json {
        print("Asked macOS to show its prompts for Mycroft Hands. Approve it for Accessibility and Screen Recording.")
    }
    let socket = Paths.defaultSocket()
    let deadline = Date().addingTimeInterval(wait)
    var last = SocketClient.ping(path: socket)
    while !(last.map { $0.trusted && $0.screenRecording } ?? false), Date() < deadline {
        Thread.sleep(forTimeInterval: 1)
        last = SocketClient.ping(path: socket) ?? last
    }
    guard let last else {
        if !json { print("No helper answers on \(socket), so the result is unknown; check with `hands desktop permissions`.") }
        exit(1)
    }
    let state = PermissionState(accessibility: last.trusted, screenRecording: last.screenRecording)
    printReport(PermissionsReport(state: state, version: last.version, bundleId: handsDesktopBundleId, executable: executablePath,
                                  source: "helper"), json: json)
    exit(state.allGranted ? 0 : 1)
}

var arguments = CommandLine.arguments.dropFirst()
// Opened as an app (Finder, `open`) with no arguments: ask for the permissions.
if arguments.isEmpty, appBundlePath != nil, isatty(0) == 0 {
    arguments = ["--request-permissions"]
}
let command = arguments.first ?? "help"
let rest = arguments.dropFirst()

switch command {
case "serve":
    let (options, positional) = parseOptions(rest, allowed: ["socket"])
    guard positional.isEmpty else { fail("serve takes no arguments\n\n\(usage)") }
    let path = options["socket"].map { ($0 as NSString).expandingTildeInPath } ?? Paths.defaultSocket()
    let service = DesktopService(backend: AXBackend())
    service.log = { log($0) }
    let server = SocketServer(path: path) { line in service.handle(line: line) }
    do {
        try server.start()
    } catch {
        fail(error.description, code: 1)
    }
    log("hands-desktop \(handsDesktopVersion) serving on \(path) (pid \(ProcessInfo.processInfo.processIdentifier))")
    if !service.backend.isTrusted {
        log("Accessibility is not granted: ui.observe and ui.act answer not_trusted until it is. " + DesktopError.notTrustedMessage)
    }
    if !service.backend.canRecordScreen {
        log("Screen Recording is not granted: ui.screenshot answers not_permitted until it is.")
    }
    for signalNumber in [SIGINT, SIGTERM] { signal(signalNumber, SIG_IGN) }
    let signals = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            log("stopping (signal \(signalNumber))")
            server.stop()
            exit(0)
        }
        source.resume()
        return source
    }
    withExtendedLifetime(signals) { RunLoop.main.run() }

case "observe":
    let (options, positional) = parseOptions(rest, allowed: ["app", "max"])
    guard positional.isEmpty else { fail("observe takes no arguments\n\n\(usage)") }
    var fields: [String: Any] = ["id": 1, "op": RequestOp.observe.rawValue]
    if let app = options["app"] { fields["app"] = app }
    if let max = options["max"] {
        guard let value = Int(max) else { fail("--max needs a number") }
        fields["maxElements"] = value
    }
    let line = requestLine(fields)
    runOffMain {
        let service = DesktopService(backend: AXBackend())
        return printResponse(service.handle(line: line))
    }

case "act":
    let (options, positional) = parseOptions(rest, allowed: ["app"])
    guard positional.count == 1, let json = positional.first else { fail("act takes one JSON argument\n\n\(usage)") }
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
        fail("the argument is not a JSON object")
    }
    let app = options["app"]
    nonisolated(unsafe) let fields = object
    runOffMain {
        let service = DesktopService(backend: AXBackend())
        var request = fields
        request["id"] = 1
        request["op"] = RequestOp.act.rawValue
        let operation = (fields["operation"] as? String).flatMap(ActOperation.init(rawValue:))
        if operation.map({ !$0.isAppLevel }) ?? true {
            var observe: [String: Any] = ["id": 0, "op": RequestOp.observe.rawValue]
            if let app { observe["app"] = app }
            let observed = service.handle(line: requestLine(observe))
            if let header = try? JSONDecoder().decode(ResponseHeader.self, from: observed), !header.ok {
                return printResponse(observed)
            }
            request["observation"] = service.currentObservation
        }
        return printResponse(service.handle(line: requestLine(request)))
    }

case "screenshot":
    let (options, positional) = parseOptions(rest, allowed: ["out", "max-width"])
    guard positional.isEmpty, let out = options["out"] else { fail("screenshot needs --out FILE\n\n\(usage)") }
    var fields: [String: Any] = ["id": 1, "op": RequestOp.screenshot.rawValue]
    if let max = options["max-width"] {
        guard let value = Int(max) else { fail("--max-width needs a number") }
        fields["maxWidth"] = value
    }
    let line = requestLine(fields)
    let path = (out as NSString).expandingTildeInPath
    runOffMain {
        let service = DesktopService(backend: AXBackend())
        let response = service.handle(line: line)
        guard let result = try? JSONDecoder().decode(ScreenshotResult.self, from: response),
              let png = Data(base64Encoded: result.png) else { return printResponse(response) }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("hands-desktop: cannot write \(path): \(error.localizedDescription)\n".utf8))
            return 1
        }
        print("\(path): \(result.width)x\(result.height), \(png.count) bytes")
        return 0
    }

case "permissions":
    let (flags, options, positional) = parseFlags(rest, flags: ["json", "request", "in-process"], options: ["wait"])
    guard positional.isEmpty else { fail("permissions takes no arguments\n\n\(usage)") }
    let json = flags.contains("json")
    let inProcess = flags.contains("in-process") || startedByLaunchd
    if flags.contains("request") { request(wait: waitOption(options), json: json, inProcess: inProcess) }
    var report = PermissionsReport(state: SystemPermissions.inProcess(), bundleId: Bundle.main.bundleIdentifier,
                                   executable: executablePath, source: "self")
    if !inProcess, let ping = SocketClient.ping(path: Paths.defaultSocket()) {
        report = PermissionsReport(state: PermissionState(accessibility: ping.trusted, screenRecording: ping.screenRecording),
                                   version: ping.version, bundleId: handsDesktopBundleId, executable: executablePath,
                                   source: "helper")
    }
    printReport(report, json: json)
    exit(report.state.allGranted ? 0 : 1)

case "--request-permissions":
    let (_, options, positional) = parseFlags(rest, flags: [], options: ["wait"])
    guard positional.isEmpty else { fail("\(command) takes no arguments\n\n\(usage)") }
    requestInProcess(wait: waitOption(options), json: false)

case "request-permission":
    // The 0.1 command: now `permissions --request`.
    let (_, options, positional) = parseFlags(rest, flags: [], options: ["wait"])
    guard positional.isEmpty else { fail("\(command) takes no arguments\n\n\(usage)") }
    request(wait: waitOption(options), json: false, inProcess: startedByLaunchd)

case "doctor":
    let state = SystemPermissions.inProcess()
    let socket = Paths.defaultSocket()
    var socketState = "not present"
    if FileManager.default.fileExists(atPath: socket) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: socket)
        let mode = (attributes?[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) } ?? "?"
        socketState = "present (mode \(mode))"
    }
    let helper = SocketClient.ping(path: socket)
    print("hands-desktop \(handsDesktopVersion)")
    print("binary:            \(executablePath)")
    print("bundle:            \(appBundlePath ?? "none (not running from Mycroft Hands.app)")")
    print("this process:      accessibility \(state.accessibility ? "granted" : "NOT granted"), "
          + "screen recording \(state.screenRecording ? "granted" : "NOT granted")")
    print("socket:            \(socket) (\(socketState))")
    if let helper {
        print("serving helper:    \(helper.version), accessibility \(helper.trusted ? "granted" : "NOT granted"), "
              + "screen recording \(helper.screenRecording ? "granted" : "NOT granted")")
    } else {
        print("serving helper:    not answering")
    }
    let granted = helper.map { $0.trusted && $0.screenRecording } ?? state.allGranted
    if !granted {
        print("""

        To grant Accessibility and Screen Recording to Mycroft Hands:
          1. Run `hands desktop permissions --request` (or open "Mycroft Hands" in ~/Applications); macOS shows its
             own dialogs and System Settings opens at the right pane.
          2. Turn on Mycroft Hands under Privacy & Security > Accessibility and > Screen & System Audio Recording.
             Use + to add ~/Applications/Mycroft Hands.app if it is not listed.
          3. The helper restarts itself after the request flow; otherwise:
             launchctl kickstart -k gui/$(id -u)/dev.mycroft.hands-desktop

        Only you can grant these; Mycroft Hands never changes privacy settings itself. When hands-desktop runs from a
        terminal, macOS checks the terminal app's permission instead of Mycroft Hands'.
        """)
    }
    exit(granted ? 0 : 1)

case "--version", "version":
    print(handsDesktopVersion)

case "help", "--help", "-h":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
