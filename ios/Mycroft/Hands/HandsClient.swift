import Foundation

/// The operations Mycroft uses, named and typed in one place (hands/docs/protocol.md).
extension HandsConnection {
    /// Starts `command` with `bash -c` as job `key`; a job already started with that key is left as it is (a replay).
    func jobStart(key: String, command: String, cwd: String?) async throws -> Reply {
        var fields: [String: Any] = ["key": key, "command": command]
        if let cwd { fields["cwd"] = cwd }
        return try await request("job.start", fields)
    }

    /// Up to `maxBytes` of a job's output from `offset`; `nextOffset`, and `eof` once the job ended and all was read.
    func jobOutput(key: String, offset: Int, maxBytes: Int) async throws -> Reply {
        try await request("job.output", ["key": key, "offset": offset, "maxBytes": maxBytes])
    }

    /// Waits up to `timeoutMs` for new output or the job's end.
    func jobWait(key: String, timeoutMs: Int) async throws {
        _ = try await request("job.wait", ["key": key, "timeoutMs": timeoutMs])
    }

    func jobStatus(key: String) async throws -> Reply {
        try await request("job.status", ["key": key])
    }

    /// Stops a job's whole process group.
    func jobCancel(key: String) async throws -> Reply {
        try await request("job.cancel", ["key": key])
    }

    func jobList() async throws -> sending [[String: Any]] {
        (try await request("job.list")["jobs"] as? [[String: Any]]) ?? []
    }

    /// Creates or replaces a file, and missing folders.
    func write(_ path: String, _ data: Data) async throws {
        _ = try await request("write", ["path": path, "append": false], payload: data)
    }

    /// Files below `path`, respecting .gitignore: records of a kind byte, a relative path and NUL; `truncated`.
    func listFiles(_ path: String, maxEntries: Int) async throws -> Reply {
        try await request("listFiles", ["path": path, "maxEntries": maxEntries])
    }

    /// Runs a short command, storing nothing: its `exitCode`, and its output (the first 16 KB) as the payload.
    func exec(_ command: String, cwd: String, timeoutMs: Int) async throws -> Reply {
        try await request("exec", ["command": command, "cwd": cwd, "timeoutMs": timeoutMs], collectOutput: true)
    }

    /// Opens `path` for reading, runs `body` with its handle and closes it, whatever `body` did.
    func reading<T: Sendable>(_ path: String, _ body: (_ read: (_ offset: Int, _ length: Int) async throws -> Data) async throws -> T) async throws -> T {
        guard let handle = try await request("open", ["path": path, "mode": "read"]).int("handle") else {
            throw Failure("could not open \(path)")
        }
        let result = await Result(catching: {
            try await body { offset, length in
                try await self.request("pread", ["handle": handle, "offset": offset, "length": length]).payload
            }
        })
        _ = try? await request("close", ["handle": handle])
        return try result.get()
    }

    /// Cua Driver's MCP tool list and server instructions, as JSON.
    func cuaTools() async throws -> Data {
        try JSONSerialization.data(withJSONObject: try await request("cua.tools").json)
    }

    /// Calls one of Cua Driver's tools: its MCP CallToolResult.
    func cuaCall(_ name: String, arguments: sending Any) async throws -> sending [String: Any] {
        try await request("cua.call", ["name": name, "arguments": arguments]).json
    }
}
