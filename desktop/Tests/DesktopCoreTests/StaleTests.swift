import Foundation
import Testing
@testable import DesktopCore

@Suite struct StaleTests {
    func errorCode(_ data: Data) -> String? { (jsonObject(data)["error"] as? NSDictionary)?["code"] as? String }

    @Test func olderObservationIsStale() throws {
        let backend = FakeBackend()
        let service = DesktopService(backend: backend, settleDelay: 0, firstObservation: 1)
        #expect(try service.observe(ObserveRequest()).observation == "o-1")
        #expect(try service.observe(ObserveRequest()).observation == "o-2")
        let data = service.handle(line: line(#"{"id":1,"op":"ui.act","observation":"o-1","operation":"PRESS","ref":"e1"}"#))
        #expect(errorCode(data) == "stale")
        let message = (jsonObject(data)["error"] as? NSDictionary)?["message"] as? String
        #expect(message?.contains("o-2") == true)
        #expect(backend.actions.isEmpty)
    }

    @Test func noObservationYetIsStale() {
        let backend = FakeBackend()
        let service = DesktopService(backend: backend, settleDelay: 0)
        #expect(errorCode(service.handle(line: line(#"{"id":1,"op":"ui.act","observation":"o-3","operation":"PRESS","ref":"e1"}"#))) == "stale")
        #expect(backend.actions.isEmpty)
    }

    @Test func unknownObservationIsStale() throws {
        let backend = FakeBackend()
        let service = DesktopService(backend: backend, settleDelay: 0, firstObservation: 5)
        _ = try service.observe(ObserveRequest())
        #expect(errorCode(service.handle(line: line(#"{"id":1,"op":"ui.act","observation":"o-999","operation":"CLICK","ref":"e1"}"#))) == "stale")
        #expect(backend.actions.isEmpty)
    }

    @Test func appLevelOperationsWithAnOldObservationAreStaleToo() throws {
        let backend = FakeBackend()
        let service = DesktopService(backend: backend, settleDelay: 0, firstObservation: 1)
        _ = try service.observe(ObserveRequest())
        _ = try service.observe(ObserveRequest())
        #expect(errorCode(service.handle(line: line(#"{"id":1,"op":"ui.act","observation":"o-1","operation":"OPEN_APP","app":"Notes"}"#))) == "stale")
        #expect(backend.actions.isEmpty)
    }

    @Test func refsFollowTheLatestObservation() throws {
        let backend = FakeBackend()
        let service = DesktopService(backend: backend, settleDelay: 0, firstObservation: 1)
        _ = try service.observe(ObserveRequest())
        backend.elements = [FakeBackend.element("other", label: "Delete")]
        let second = try service.observe(ObserveRequest())
        #expect(second.elements.map(\.ref) == ["e1"])
        _ = try service.act(ActRequest(observation: second.observation, operation: .press, ref: "e1"))
        #expect(backend.performed == ["PRESS Delete"])
        // e2 existed only in the first observation.
        #expect(throws: DesktopError.notFound("Unknown ref e2 in observation o-2.")) {
            try service.act(ActRequest(observation: second.observation, operation: .focus, ref: "e2"))
        }
    }

    @Test func aFailedObserveKeepsThePreviousObservation() throws {
        let backend = FakeBackend()
        let service = DesktopService(backend: backend, settleDelay: 0, firstObservation: 1)
        _ = try service.observe(ObserveRequest())
        backend.observeError = DesktopError.notFound("gone")
        #expect(throws: DesktopError.self) { try service.observe(ObserveRequest(app: "Gone")) }
        #expect(service.currentObservation == "o-1")
        #expect(try service.act(ActRequest(observation: "o-1", operation: .press, ref: "e1")).result == "Did PRESS New Note")
    }

    @Test func backendStaleErrorsPassThrough() throws {
        let backend = FakeBackend()
        let service = DesktopService(backend: backend, settleDelay: 0, firstObservation: 1)
        _ = try service.observe(ObserveRequest())
        backend.performError = DesktopError.stale("The window changed since the observation. Call ui.observe again.")
        #expect(throws: DesktopError.stale("The window changed since the observation. Call ui.observe again.")) {
            try service.act(ActRequest(observation: "o-1", operation: .press, ref: "e1"))
        }
    }
}
