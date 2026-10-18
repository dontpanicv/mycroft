import Foundation
import Testing
@testable import DesktopCore

@Suite struct DispatchTests {
    func makeService(_ backend: FakeBackend = FakeBackend()) -> (DesktopService, FakeBackend) {
        (DesktopService(backend: backend, settleDelay: 0, firstObservation: 17), backend)
    }

    func response(_ service: DesktopService, _ text: String) -> NSDictionary { jsonObject(service.handle(line: line(text))) }

    func errorCode(_ object: NSDictionary) -> String? { (object["error"] as? NSDictionary)?["code"] as? String }

    // MARK: Observe

    @Test func observeAssignsIdsRefsAndIndexes() throws {
        let (service, backend) = makeService()
        let object = response(service, #"{"id":1,"op":"ui.observe"}"#)
        #expect(object["ok"] as? Bool == true)
        #expect(object["observation"] as? String == "o-17")
        #expect(object["application"] as? String == "Notes")
        #expect(object["bundleId"] as? String == "com.apple.Notes")
        #expect(object["window"] as? String == "Shopping list")
        #expect(object["otherWindows"] as? Int == 2)
        let elements = object["elements"] as? [NSDictionary] ?? []
        #expect(elements.map { $0["ref"] as? String } == ["e1", "e2", "e3", "e4"])
        #expect(elements.map { $0["index"] as? Int } == [1, 2, 3, 4])
        #expect(elements[1]["value"] as? String == "Milk")
        #expect(elements[0]["value"] is NSNull)
        #expect(backend.observedApps == [nil])
        #expect(backend.observedLimits == [150])
        #expect(service.currentObservation == "o-17")
        #expect(response(service, #"{"id":2,"op":"ui.observe"}"#)["observation"] as? String == "o-18")
    }

    @Test func observePassesTheAppAndLimit() {
        let (service, backend) = makeService()
        _ = response(service, #"{"id":1,"op":"ui.observe","app":"  com.apple.Notes ","maxElements":2}"#)
        _ = response(service, #"{"id":2,"op":"ui.observe","app":""}"#)
        #expect(backend.observedApps == ["com.apple.Notes", nil])
        #expect(backend.observedLimits == [2, 150])
    }

    @Test func observeTruncatesToMaxElements() {
        let (service, _) = makeService()
        let object = response(service, #"{"id":1,"op":"ui.observe","maxElements":2}"#)
        #expect((object["elements"] as? [Any])?.count == 2)
    }

    @Test func observeRejectsBadMaxElements() {
        let (service, backend) = makeService()
        for value in ["0", "-3", "5000"] {
            #expect(errorCode(response(service, #"{"id":1,"op":"ui.observe","maxElements":\#(value)}"#)) == "invalid")
        }
        #expect(errorCode(response(service, #"{"id":1,"op":"ui.observe","maxElements":"many"}"#)) == "invalid")
        #expect(backend.observedApps.isEmpty)
    }

    @Test func observeCapsAvailableLists() {
        let backend = FakeBackend()
        backend.available.apps = (0..<250).map { "App \($0)" }
        backend.available.menus = (0..<400).map { "Menu > Item \($0)" }
        let (service, _) = makeService(backend)
        let available = response(service, #"{"id":1,"op":"ui.observe"}"#)["available"] as? NSDictionary
        #expect((available?["apps"] as? [String])?.count == 200)
        #expect((available?["menus"] as? [String])?.count == 300)
    }

    @Test func observeReportsBackendErrors() {
        let backend = FakeBackend()
        backend.observeError = DesktopError.notFound("No running app matches “Nope”.")
        let (service, _) = makeService(backend)
        let object = response(service, #"{"id":"q","op":"ui.observe","app":"Nope"}"#)
        #expect(object["id"] as? String == "q")
        #expect(errorCode(object) == "not_found")
        #expect(service.currentObservation == nil)
    }

    // MARK: Trust and lines

    @Test func notTrustedRefusesObserveAndAct() {
        let backend = FakeBackend()
        backend.isTrusted = false
        let (service, _) = makeService(backend)
        let observe = response(service, #"{"id":1,"op":"ui.observe"}"#)
        #expect(errorCode(observe) == "not_trusted")
        #expect(((observe["error"] as? NSDictionary)?["message"] as? String)?.contains("Privacy & Security > Accessibility") == true)
        #expect(errorCode(response(service, #"{"id":2,"op":"ui.act","operation":"OPEN_APP","app":"Notes"}"#)) == "not_trusted")
        #expect(backend.observedApps.isEmpty)
        #expect(backend.actions.isEmpty)
        let ping = response(service, #"{"id":3,"op":"ping"}"#)
        #expect(ping["ok"] as? Bool == true)
        #expect(ping["trusted"] as? Bool == false)
    }

    @Test func malformedLinesAreInvalid() {
        let (service, _) = makeService()
        let garbage = response(service, "not json")
        #expect(errorCode(garbage) == "invalid")
        #expect(garbage["id"] is NSNull)
        #expect(errorCode(response(service, "[1,2]")) == "invalid")
        let noOp = response(service, #"{"id":5}"#)
        #expect(errorCode(noOp) == "invalid")
        #expect(noOp["id"] as? Int == 5)
        let unknown = response(service, #"{"id":6,"op":"shell.exec"}"#)
        #expect(errorCode(unknown) == "invalid")
        #expect(((unknown["error"] as? NSDictionary)?["message"] as? String)?.contains("shell.exec") == true)
    }

    // MARK: Act

    @Test func pressActsOnTheReferencedElement() throws {
        let backend = FakeBackend()
        backend.fingerprints = [fingerprint("Shopping list"), fingerprint("New note")]
        let (service, _) = makeService(backend)
        _ = response(service, #"{"id":1,"op":"ui.observe"}"#)
        let object = response(service, #"{"id":2,"op":"ui.act","observation":"o-17","operation":"PRESS","ref":"e1"}"#)
        #expect(object["ok"] as? Bool == true)
        #expect(object["result"] as? String == "Did PRESS New Note")
        #expect(object["screenChanged"] as? Bool == true)
        guard case .press(let element, let target) = try #require(backend.actions.first) else {
            Issue.record("expected a press")
            return
        }
        #expect((element.handle as? FakeBackend.Handle)?.id == "new-note")
        #expect(target == backend.target)
        #expect(backend.scopes == [.app(backend.target), .app(backend.target)])
    }

    @Test func unchangedScreenIsReported() {
        let backend = FakeBackend()
        backend.fingerprints = [fingerprint("Shopping list")]
        let (service, _) = makeService(backend)
        _ = response(service, #"{"id":1,"op":"ui.observe"}"#)
        let object = response(service, #"{"id":2,"op":"ui.act","observation":"o-17","operation":"CLICK","ref":"e4"}"#)
        #expect(object["screenChanged"] as? Bool == false)
    }

    @Test func appLevelOperationsFingerprintTheFrontmostApp() throws {
        let (service, backend) = makeService()
        let open = response(service, #"{"id":1,"op":"ui.act","operation":"OPEN_APP","app":"Safari"}"#)
        #expect(open["ok"] as? Bool == true)
        #expect(backend.scopes == [.frontmost, .frontmost])
        _ = response(service, #"{"id":2,"op":"ui.act","operation":"OPEN_URL","url":"example.com/x"}"#)
        _ = response(service, #"{"id":3,"op":"ui.act","operation":"OPEN_FOLDER","path":"~"}"#)
        _ = response(service, #"{"id":4,"op":"ui.act","operation":"QUIT_APP","app":"Safari"}"#)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        #expect(backend.performed == ["OPEN_APP Safari", "OPEN_URL https://example.com/x", "OPEN_FOLDER \(home)", "QUIT_APP Safari"])
    }

    @Test func everyElementOperationReachesTheBackend() {
        let (service, backend) = makeService()
        _ = response(service, #"{"id":1,"op":"ui.observe"}"#)
        let lines = [
            #"{"operation":"SELECT","ref":"e3"}"#,
            #"{"operation":"FOCUS","ref":"e2"}"#,
            #"{"operation":"TYPE_TEXT","ref":"e2","text":"Eggs"}"#,
            #"{"operation":"TYPE_TEXT","text":"Bread"}"#,
            #"{"operation":"PRESS_KEY","key":"z","modifiers":["cmd"]}"#,
            #"{"operation":"PRESS_KEY","key":"down","times":3}"#,
            #"{"operation":"SCROLL","direction":"down","times":2}"#,
            #"{"operation":"MENU","menu":"Format > Bold"}"#,
        ]
        for (index, text) in lines.enumerated() {
            let request = text.replacingOccurrences(of: "{", with: #"{"id":\#(index),"op":"ui.act","observation":"o-17","#)
            #expect(response(service, request)["ok"] as? Bool == true, "\(text)")
        }
        #expect(backend.performed == [
            "SELECT Groceries", "FOCUS Note body", "TYPE_TEXT 4 characters into Note body", "TYPE_TEXT 5 characters into the focused element",
            "PRESS_KEY cmd+z x1", "PRESS_KEY down x3", "SCROLL down x2", "MENU Format > Bold",
        ])
    }

    @Test func refRules() {
        let (service, backend) = makeService()
        _ = response(service, #"{"id":1,"op":"ui.observe"}"#)
        func act(_ fields: String) -> NSDictionary {
            response(service, #"{"id":9,"op":"ui.act","observation":"o-17",\#(fields)}"#)
        }
        #expect(errorCode(act(#""operation":"PRESS""#)) == "invalid")
        #expect(errorCode(act(#""operation":"PRESS","ref":"e99""#)) == "not_found")
        // The row has no press action, the text box no select.
        #expect(errorCode(act(#""operation":"PRESS","ref":"e3""#)) == "invalid")
        #expect(errorCode(act(#""operation":"SELECT","ref":"e2""#)) == "invalid")
        #expect(errorCode(act(#""operation":"TYPE_TEXT","ref":"e1","text":"x""#)) == "invalid")
        #expect(errorCode(act(#""operation":"FOCUS","ref":"e1""#)) == "invalid")
        // CLICK is the fallback for any element.
        #expect(act(#""operation":"CLICK","ref":"e1""#)["ok"] as? Bool == true)
        #expect(backend.performed == ["CLICK New Note"])
    }

    @Test func fieldRules() {
        let (service, backend) = makeService()
        _ = response(service, #"{"id":1,"op":"ui.observe"}"#)
        func act(_ fields: String) -> String? {
            errorCode(response(service, #"{"id":9,"op":"ui.act","observation":"o-17",\#(fields)}"#))
        }
        #expect(act(#""operation":"OPEN_APP""#) == "invalid")
        #expect(act(#""operation":"OPEN_APP","app":"  ""#) == "invalid")
        #expect(act(#""operation":"QUIT_APP""#) == "invalid")
        #expect(act(#""operation":"OPEN_URL","url":"file:///etc/hosts""#) == "invalid")
        #expect(act(#""operation":"OPEN_URL","url":"javascript:alert(1)""#) == "invalid")
        #expect(act(#""operation":"OPEN_FOLDER""#) == "invalid")
        #expect(act(#""operation":"TYPE_TEXT""#) == "invalid")
        #expect(act(#""operation":"TYPE_TEXT","text":"""#) == "invalid")
        #expect(act(#""operation":"TYPE_TEXT","text":"\#(String(repeating: "a", count: 10_001))""#) == "invalid")
        #expect(act(#""operation":"PRESS_KEY""#) == "invalid")
        #expect(act(#""operation":"PRESS_KEY","key":"hyper""#) == "invalid")
        #expect(act(#""operation":"PRESS_KEY","key":"a","modifiers":["super"]"#) == "invalid")
        #expect(act(#""operation":"PRESS_KEY","key":"a","times":0"#) == "invalid")
        #expect(act(#""operation":"PRESS_KEY","key":"a","times":101"#) == "invalid")
        #expect(act(#""operation":"SCROLL""#) == "invalid")
        #expect(act(#""operation":"SCROLL","direction":"sideways""#) == "invalid")
        #expect(act(#""operation":"SCROLL","direction":"up","times":51"#) == "invalid")
        #expect(act(#""operation":"MENU""#) == "invalid")
        #expect(act(#""operation":"MENU","menu":"File""#) == "invalid")
        #expect(act(#""operation":"FLY""#) == "invalid")
        #expect(backend.actions.isEmpty)
    }

    @Test func elementOperationsNeedAnObservation() {
        let (service, backend) = makeService()
        _ = response(service, #"{"id":1,"op":"ui.observe"}"#)
        for operation in ["PRESS", "SELECT", "CLICK", "FOCUS", "TYPE_TEXT", "PRESS_KEY", "SCROLL", "MENU"] {
            let object = response(service, #"{"id":2,"op":"ui.act","operation":"\#(operation)","ref":"e1","text":"a","key":"a","direction":"up","menu":"A > B"}"#)
            #expect(errorCode(object) == "invalid", "\(operation)")
        }
        #expect(backend.actions.isEmpty)
    }

    @Test func backendErrorsKeepTheirCodes() {
        let backend = FakeBackend()
        let (service, _) = makeService(backend)
        _ = response(service, #"{"id":1,"op":"ui.observe"}"#)
        backend.performError = DesktopError.stale("“New Note” changed since the observation.")
        #expect(errorCode(response(service, #"{"id":2,"op":"ui.act","observation":"o-17","operation":"PRESS","ref":"e1"}"#)) == "stale")
        backend.performError = DesktopError.failed("The app refused.")
        #expect(errorCode(response(service, #"{"id":3,"op":"ui.act","observation":"o-17","operation":"PRESS","ref":"e1"}"#)) == "failed")
        struct Other: Error {}
        backend.performError = Other()
        #expect(errorCode(response(service, #"{"id":4,"op":"ui.act","observation":"o-17","operation":"PRESS","ref":"e1"}"#)) == "failed")
    }

    @Test func randomObservationSeedsDiffer() {
        let ids = (0..<5).map { _ in
            let service = DesktopService(backend: FakeBackend(), settleDelay: 0)
            return (try? service.observe(ObserveRequest()))?.observation ?? ""
        }
        #expect(Set(ids).count > 1)
        #expect(ids.allSatisfy { $0.hasPrefix("o-") })
    }
}
