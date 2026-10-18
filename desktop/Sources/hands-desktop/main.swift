import DesktopCore
import Foundation

let usage = """
hands-desktop \(handsDesktopVersion): the macOS desktop-control helper of Mycroft's `hands`.

Usage:
  hands-desktop serve [--socket PATH]         Serve ui.observe / ui.act on a Unix socket (newline-delimited JSON).
                                              Default: $HANDS_STATE_DIR/desktop.sock, else
                                              ~/Library/Application Support/hands/desktop.sock
  hands-desktop observe [--app X] [--max N]   Print one observation as JSON.
  hands-desktop act '<json>' [--app X]        Run one ui.act and print the result. The observation is taken fresh
                                              (of --app or the frontmost app), so refs match a preceding `observe`
                                              only if the screen has not changed.
  hands-desktop doctor                        Report whether Accessibility is granted and how to grant it.
  hands-desktop request-permission            Ask macOS to show its Accessibility permission dialog.
  hands-desktop --version | help
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

let arguments = CommandLine.arguments.dropFirst()
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
        log("Accessibility is not granted: requests answer not_trusted until it is. " + DesktopError.notTrustedMessage)
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

case "doctor":
    let trusted = AXBackend().isTrusted
    let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let socket = Paths.defaultSocket()
    var socketState = "not present"
    if FileManager.default.fileExists(atPath: socket) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: socket)
        let mode = (attributes?[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) } ?? "?"
        socketState = "present (mode \(mode))"
    }
    print("hands-desktop \(handsDesktopVersion)")
    print("binary:        \(binary)")
    print("accessibility: \(trusted ? "granted" : "NOT granted")")
    print("socket:        \(socket) (\(socketState))")
    if !trusted {
        print("""

        To grant Accessibility:
          1. Run `hands-desktop request-permission` in the logged-in GUI session (or let the LaunchAgent start it);
             macOS shows its own dialog.
          2. Open System Settings > Privacy & Security > Accessibility and turn on hands-desktop
             (\(binary)). Use + to add it if it is not listed.
          3. Restart the helper: launchctl kickstart -k gui/$(id -u)/dev.mycroft.hands-desktop

        Only you can grant this; hands-desktop never changes privacy settings itself. When hands-desktop runs from a
        terminal, macOS checks the terminal app's permission instead of the binary's.
        """)
    }
    exit(trusted ? 0 : 1)

case "request-permission":
    let trusted = AXBackend.requestTrust()
    if trusted {
        print("Accessibility is already granted.")
    } else {
        print("macOS was asked to show its Accessibility dialog. Turn on hands-desktop in System Settings > Privacy & "
              + "Security > Accessibility, then restart the helper. Only you can grant this.")
    }
    exit(trusted ? 0 : 1)

case "--version", "version":
    print(handsDesktopVersion)

case "help", "--help", "-h":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
