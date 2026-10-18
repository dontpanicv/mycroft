import Foundation
import UIKit

@MainActor
final class Journal: ObservableObject {
    static let shared = Journal()
    @Published var status = "Ready"
    @Published var recent: [String] = []
    let directory: URL
    private let handle: FileHandle

    private init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("events.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url)
            }
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } catch { fatalError("Cannot initialize experiment journal: \(error)") }
    }

    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["event"] = event
        row["wall"] = Date().timeIntervalSince1970
        row["uptime"] = ProcessInfo.processInfo.systemUptime
        row["pid"] = ProcessInfo.processInfo.processIdentifier
        row["appState"] = UIApplication.shared.applicationState.rawValue
        row["protectedDataAvailable"] = UIApplication.shared.isProtectedDataAvailable
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(10)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch { fatalError("Experiment evidence could not be persisted: \(error)") }
        status = event
        recent = Array((recent + ["\(event): \(fields)"]).suffix(8))
        print("SPIKE \(event) \(fields)")
    }

    func error(_ event: String, _ error: Error) {
        let e = error as NSError
        emit(event, ["domain": e.domain, "code": e.code, "description": e.localizedDescription,
                     "userInfo": String(describing: e.userInfo)])
    }
}
