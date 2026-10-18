import Darwin
import Foundation
import Testing
@testable import DesktopCore

/// Serves the fake backend on a temporary socket and talks to it like `hands` would.
@Suite(.serialized) struct SocketTests {
    func serve(_ backend: FakeBackend = FakeBackend()) throws -> (SocketServer, DesktopService) {
        let service = DesktopService(backend: backend, settleDelay: 0, firstObservation: 1)
        let server = SocketServer(path: temporarySocketPath()) { service.handle(line: $0) }
        try server.start()
        return (server, service)
    }

    @Test func observeThenActRoundTrip() throws {
        let backend = FakeBackend()
        backend.fingerprints = [fingerprint("Shopping list"), fingerprint("Untitled")]
        let (server, _) = try serve(backend)
        defer { server.stop() }

        var info = stat()
        #expect(lstat(server.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect((info.st_mode & S_IFMT) == S_IFSOCK)

        let client = try LineClient(path: server.path)
        client.send(#"{"id":"p","op":"ping"}"# + "\n")
        let ping = jsonObject(try #require(client.readLine()))
        #expect(ping["id"] as? String == "p")
        #expect(ping["trusted"] as? Bool == true)

        client.send(#"{"id":1,"op":"ui.observe","maxElements":10}"# + "\n")
        let observation = jsonObject(try #require(client.readLine()))
        #expect(observation["ok"] as? Bool == true)
        #expect(observation["observation"] as? String == "o-1")
        #expect((observation["elements"] as? [NSDictionary])?.first?["ref"] as? String == "e1")

        client.send(#"{"id":2,"op":"ui.act","observation":"o-1","operation":"PRESS","ref":"e1"}"# + "\n")
        let act = jsonObject(try #require(client.readLine()))
        #expect(act["id"] as? Int == 2)
        #expect(act["ok"] as? Bool == true)
        #expect(act["result"] as? String == "Did PRESS New Note")
        #expect(act["screenChanged"] as? Bool == true)

        client.send(#"{"id":3,"op":"ui.act","observation":"o-0","operation":"PRESS","ref":"e1"}"# + "\n")
        let stale = jsonObject(try #require(client.readLine()))
        #expect((stale["error"] as? NSDictionary)?["code"] as? String == "stale")
        #expect(backend.performed == ["PRESS New Note"])
    }

    @Test func pipelinedRequestsAnswerInOrder() throws {
        let (server, _) = try serve()
        defer { server.stop() }
        let client = try LineClient(path: server.path)
        // Several lines in one write, a CRLF line and a blank line.
        client.send(#"{"id":1,"op":"ui.observe"}"# + "\n\n" + #"{"id":2,"op":"ping"}"# + "\r\n" + #"{"id":3,"op":"ui.observe"}"# + "\n")
        let ids = (0..<3).compactMap { _ in client.readLine().map(jsonObject)?["id"] as? Int }
        #expect(ids == [1, 2, 3])
    }

    @Test func badLinesGetErrorsAndTheConnectionStaysOpen() throws {
        let (server, _) = try serve()
        defer { server.stop() }
        let client = try LineClient(path: server.path)
        client.send("this is not json\n")
        let error = jsonObject(try #require(client.readLine()))
        #expect(error["ok"] as? Bool == false)
        #expect((error["error"] as? NSDictionary)?["code"] as? String == "invalid")
        client.send(#"{"id":4,"op":"ping"}"# + "\n")
        #expect(jsonObject(try #require(client.readLine()))["id"] as? Int == 4)
    }

    @Test func concurrentClientsAreServed() async throws {
        let (server, _) = try serve()
        defer { server.stop() }
        let path = server.path
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for clientNumber in 0..<6 {
                group.addTask {
                    let client = try LineClient(path: path)
                    var answered = 0
                    for request in 0..<10 {
                        let id = clientNumber * 100 + request
                        client.send(#"{"id":\#(id),"op":"\#(request % 2 == 0 ? "ui.observe" : "ping")"}"# + "\n")
                        if let reply = client.readLine(), jsonObject(reply)["id"] as? Int == id { answered += 1 }
                    }
                    return answered
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(counts == Array(repeating: 10, count: 6))
    }

    @Test func requestsAreSerialized() async throws {
        /// Records how many requests are inside the handler at once.
        final class Gauge: @unchecked Sendable {
            let lock = NSLock()
            var inside = 0
            var most = 0
            func enter() { lock.lock(); inside += 1; most = max(most, inside); lock.unlock() }
            func leave() { lock.lock(); inside -= 1; lock.unlock() }
        }
        let gauge = Gauge()
        let server = SocketServer(path: temporarySocketPath()) { line in
            gauge.enter()
            Thread.sleep(forTimeInterval: 0.01)
            gauge.leave()
            return line
        }
        try server.start()
        defer { server.stop() }
        let path = server.path
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let client = try LineClient(path: path)
                    for index in 0..<5 {
                        client.send("{\"n\":\(index)}\n")
                        _ = client.readLine()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(gauge.most == 1)
    }

    @Test func liveSocketIsNotTakenOverAndStopRemovesIt() throws {
        let (server, _) = try serve()
        let second = SocketServer(path: server.path) { $0 }
        #expect(throws: SocketServer.StartError.self) { try second.start() }
        // The first server still answers.
        let client = try LineClient(path: server.path)
        client.send(#"{"id":1,"op":"ping"}"# + "\n")
        #expect(client.readLine() != nil)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: server.path))
    }

    @Test func staleSocketFileIsReplaced() throws {
        let path = temporarySocketPath()
        // A socket file nobody listens on, as a crashed helper leaves behind.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(FileManager.default.fileExists(atPath: path))

        let server = SocketServer(path: path) { _ in Data(#"{"ok":true}"#.utf8) }
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: path)
        client.send("{}\n")
        #expect(client.readLine() == #"{"ok":true}"#)
    }

    @Test func regularFileIsNotReplaced() throws {
        let path = temporarySocketPath()
        FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))
        defer { unlink(path) }
        #expect(throws: SocketServer.StartError.self) { try SocketServer(path: path) { $0 }.start() }
        #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
    }

    @Test func overlongPathIsRefused() {
        let path = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: SocketServer.StartError.self) { try SocketServer(path: path) { $0 }.start() }
    }

    @Test func clientDisconnectingMidRequestDoesNotStopTheServer() throws {
        let server = SocketServer(path: temporarySocketPath()) { line in
            Thread.sleep(forTimeInterval: 0.05)
            return line
        }
        try server.start()
        defer { server.stop() }
        do {
            let leaving = try LineClient(path: server.path)
            leaving.send("{\"a\":1}\n{\"a\":2}\n")
        }
        Thread.sleep(forTimeInterval: 0.2)
        let client = try LineClient(path: server.path)
        client.send("{\"b\":1}\n")
        #expect(client.readLine() == "{\"b\":1}")
    }
}
