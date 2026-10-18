import Foundation
import JavaScriptCore

// A deterministic workload isolates lifecycle behavior from model latency and credentials.
@MainActor
final class JavaScriptWork {
    private var context: JSContext?
    private var writeError: Error?
    private let sourceURL: URL
    private let stateURL: URL
    private let reloadAt: Int
    private(set) var steps = 0
    private(set) var generation = 1

    init(reloadAt: Int, resume: Bool = false) throws {
        self.reloadAt = reloadAt
        sourceURL = Journal.shared.directory.appendingPathComponent("agent.js")
        stateURL = Journal.shared.directory.appendingPathComponent("checkpoint.json")
        if !resume {
            try Self.initialSource.write(to: sourceURL, atomically: true, encoding: .utf8)
            try "{\"steps\":0,\"score\":0,\"reloaded\":false}".write(to: stateURL, atomically: true, encoding: .utf8)
        }
        try load()
    }

    private func load() throws {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let state = try String(contentsOf: stateURL, encoding: .utf8)
        guard let next = JSContext() else { throw failure("Cannot create JSContext") }
        let read: @convention(block) () -> String = { [sourceURL] in
            (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        }
        let write: @convention(block) (String) -> Void = { [weak self] source in
            guard let self else { return }
            do { try source.write(to: self.sourceURL, atomically: true, encoding: .utf8) }
            catch { self.writeError = error }
        }
        next.setObject(read, forKeyedSubscript: "readSelf" as NSString)
        next.setObject(write, forKeyedSubscript: "writeSelf" as NSString)
        next.setObject(reloadAt, forKeyedSubscript: "reloadAt" as NSString)
        next.evaluateScript("var state = \(state);\n" + source)
        if let exception = next.exception { throw failure(exception.toString()) }
        context = next
        steps = Int(next.evaluateScript("state.steps")!.toInt32())
        generation = Int(next.evaluateScript("generation")!.toInt32())
        Journal.shared.emit("runtime_loaded", ["generation": generation, "steps": steps])
    }

    func tick() throws {
        guard let context, let result = context.evaluateScript("tick()") else {
            throw failure("No runtime")
        }
        if let exception = context.exception { throw failure(exception.toString()) }
        if let writeError { throw writeError }
        guard let state = context.evaluateScript("JSON.stringify(state)")?.toString() else {
            throw failure("Missing serialized state")
        }
        try state.write(to: stateURL, atomically: true, encoding: .utf8)
        steps = Int(context.evaluateScript("state.steps")!.toInt32())
        let score = Int(context.evaluateScript("state.score")!.toInt32())
        let expected = min(steps, reloadAt) + max(0, steps - reloadAt) * 10
        guard score == expected else { throw failure("State mismatch: \(score) != \(expected)") }
        Journal.shared.emit("tick", ["steps": steps, "generation": generation, "score": score])
        if result.toBool() {
            let savedSteps = steps
            self.context = nil
            try load()
            guard steps == savedSteps, generation == 2 else { throw failure("Reload lost state or source") }
            Journal.shared.emit("reload_verified", ["steps": steps, "generation": generation])
        }
    }

    private func failure(_ message: String?) -> NSError {
        NSError(domain: "JavaScriptWork", code: 1, userInfo: [NSLocalizedDescriptionKey: message ?? "JS exception"])
    }

    private static let initialSource = """
    const generation = 1;
    function tick() {
      state.steps += 1;
      state.score += generation === 1 ? 1 : 10;
      if (state.steps === reloadAt && !state.reloaded) {
        const source = readSelf();
        const replacement = source.replace('const generation = 1;', 'const generation = 2;');
        if (replacement === source) throw new Error('Self-edit did not change source');
        writeSelf(replacement);
        state.reloaded = true;
        return true;
      }
      return false;
    }
    """
}
