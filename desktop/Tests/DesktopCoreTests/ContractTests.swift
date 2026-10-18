import Foundation
import Testing
@testable import DesktopCore

/// Every request and response shape of docs/desktop-protocol.md.
@Suite struct ContractTests {
    let decoder = JSONDecoder()

    // MARK: Requests

    @Test func observeRequestWithoutFields() throws {
        let request = try decoder.decode(ObserveRequest.self, from: line(#"{"id":1,"op":"ui.observe"}"#))
        #expect(request == ObserveRequest(app: nil, maxElements: nil))
    }

    @Test func observeRequestWithFields() throws {
        let request = try decoder.decode(ObserveRequest.self, from: line(#"{"id":"r1","op":"ui.observe","app":"com.apple.Notes","maxElements":40}"#))
        #expect(request == ObserveRequest(app: "com.apple.Notes", maxElements: 40))
    }

    @Test func observeRequestRoundTrip() throws {
        let request = ObserveRequest(app: "Notes", maxElements: 10)
        #expect(try decoder.decode(ObserveRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    static let actLines: [(String, ActRequest)] = [
        (#"{"observation":"o-1","operation":"OPEN_APP","app":"Notes"}"#, ActRequest(observation: "o-1", operation: .openApp, app: "Notes")),
        (#"{"observation":"o-1","operation":"QUIT_APP","app":"com.apple.Safari"}"#, ActRequest(observation: "o-1", operation: .quitApp, app: "com.apple.Safari")),
        (#"{"observation":"o-1","operation":"OPEN_URL","url":"https://example.com/a"}"#, ActRequest(observation: "o-1", operation: .openURL, url: "https://example.com/a")),
        (#"{"observation":"o-1","operation":"OPEN_FOLDER","path":"~/Documents"}"#, ActRequest(observation: "o-1", operation: .openFolder, path: "~/Documents")),
        (#"{"observation":"o-1","operation":"PRESS","ref":"e1"}"#, ActRequest(observation: "o-1", operation: .press, ref: "e1")),
        (#"{"observation":"o-1","operation":"SELECT","ref":"e3"}"#, ActRequest(observation: "o-1", operation: .select, ref: "e3")),
        (#"{"observation":"o-1","operation":"CLICK","ref":"e4"}"#, ActRequest(observation: "o-1", operation: .click, ref: "e4")),
        (#"{"observation":"o-1","operation":"FOCUS","ref":"e2"}"#, ActRequest(observation: "o-1", operation: .focus, ref: "e2")),
        (#"{"observation":"o-1","operation":"TYPE_TEXT","text":"Eggs","ref":"e2"}"#, ActRequest(observation: "o-1", operation: .typeText, ref: "e2", text: "Eggs")),
        (#"{"observation":"o-1","operation":"TYPE_TEXT","text":"Eggs"}"#, ActRequest(observation: "o-1", operation: .typeText, text: "Eggs")),
        (#"{"observation":"o-1","operation":"PRESS_KEY","key":"z","modifiers":["cmd","shift"],"times":2}"#,
         ActRequest(observation: "o-1", operation: .pressKey, key: "z", modifiers: ["cmd", "shift"], times: 2)),
        (#"{"observation":"o-1","operation":"PRESS_KEY","key":"return"}"#, ActRequest(observation: "o-1", operation: .pressKey, key: "return")),
        (#"{"observation":"o-1","operation":"SCROLL","direction":"down","times":3}"#, ActRequest(observation: "o-1", operation: .scroll, times: 3, direction: .down)),
        (#"{"observation":"o-1","operation":"SCROLL","direction":"up"}"#, ActRequest(observation: "o-1", operation: .scroll, direction: .up)),
        (#"{"observation":"o-1","operation":"MENU","menu":"File > New Note"}"#, ActRequest(observation: "o-1", operation: .menu, menu: "File > New Note")),
    ]

    @Test(arguments: 0..<actLines.count)
    func actRequestDecodes(_ index: Int) throws {
        let (text, expected) = Self.actLines[index]
        #expect(try decoder.decode(ActRequest.self, from: line(text)) == expected)
        // And back again.
        #expect(try decoder.decode(ActRequest.self, from: JSONEncoder().encode(expected)) == expected)
    }

    @Test func everyOperationOfTheSpecIsCovered() {
        let covered = Set(Self.actLines.map(\.1.operation))
        #expect(covered == Set(ActOperation.allCases))
        #expect(ActOperation.allCases.map(\.rawValue) == ["OPEN_APP", "QUIT_APP", "OPEN_URL", "OPEN_FOLDER", "PRESS", "SELECT", "CLICK",
                                                          "FOCUS", "TYPE_TEXT", "PRESS_KEY", "SCROLL", "MENU"])
    }

    @Test func unknownOperationDoesNotDecode() {
        #expect(throws: DecodingError.self) {
            try decoder.decode(ActRequest.self, from: line(#"{"observation":"o-1","operation":"RUN_SHELL"}"#))
        }
    }

    @Test func badDirectionDoesNotDecode() {
        #expect(throws: DecodingError.self) {
            try decoder.decode(ActRequest.self, from: line(#"{"observation":"o-1","operation":"SCROLL","direction":"left"}"#))
        }
    }

    // MARK: Responses

    static let specObservation = """
    {
      "observation": "o-17",
      "application": "Notes",
      "bundleId": "com.apple.Notes",
      "window": "Shopping list",
      "otherWindows": 2,
      "elements": [
        { "ref": "e1", "index": 1, "role": "button", "label": "New Note", "value": null, "place": "toolbar", "operations": ["press"] },
        { "ref": "e2", "index": 2, "role": "text area", "label": "Note body", "value": "Milk", "place": "content", "operations": ["type", "focus"] }
      ],
      "available": {
        "apps": ["Notes", "Safari", "Terminal"],
        "folders": ["Desktop", "Documents", "Downloads"],
        "sites": [],
        "menus": ["File > New Note", "Format > Bold"]
      },
      "secureInputActive": false
    }
    """

    @Test func specObservationRoundTrips() throws {
        let observation = try decoder.decode(Observation.self, from: line(Self.specObservation))
        #expect(observation.observation == "o-17")
        #expect(observation.elements[0].value == nil)
        #expect(observation.elements[1].operations == [.type, .focus])
        #expect(observation.elements[0].place == .toolbar)
        let encoded = try JSONEncoder().encode(observation)
        #expect(jsonObject(encoded) == jsonObject(Self.specObservation))
    }

    @Test func nullsAreWrittenExplicitly() throws {
        let observation = Observation(observation: "o-1", application: "Finder", bundleId: nil, window: nil, otherWindows: 0,
                                      elements: [UIElement(ref: "e1", index: 1, role: "row", label: "Docs", value: nil, place: .sidebar, operations: [.select, .click])],
                                      available: Available(), secureInputActive: true)
        let object = jsonObject(try JSONEncoder().encode(observation))
        #expect(object["bundleId"] is NSNull)
        #expect(object["window"] is NSNull)
        #expect(((object["elements"] as? [NSDictionary])?.first?["value"]) is NSNull)
        #expect(object["secureInputActive"] as? Bool == true)
    }

    @Test func placesAndElementOperationsMatchTheSpec() {
        #expect(Place.allCases.map(\.rawValue) == ["toolbar", "sidebar", "content", "dialog", "menu"])
        #expect(ElementOperation.allCases.map(\.rawValue) == ["press", "select", "click", "focus", "type"])
    }

    @Test func actResultShape() throws {
        let data = Wire.success(id: .string("a1"), ActResult(result: "Pressed “New Note” in Notes", screenChanged: true))
        #expect(jsonObject(data) == jsonObject(#"{"id":"a1","ok":true,"result":"Pressed “New Note” in Notes","screenChanged":true}"#))
        #expect(try decoder.decode(ActResult.self, from: data) == ActResult(result: "Pressed “New Note” in Notes", screenChanged: true))
    }

    @Test func successResponseFlattensTheResult() throws {
        let observation = try decoder.decode(Observation.self, from: line(Self.specObservation))
        let data = Wire.success(id: .int(7), observation)
        let object = jsonObject(data)
        #expect(object["id"] as? Int == 7)
        #expect(object["ok"] as? Bool == true)
        #expect(object["observation"] as? String == "o-17")
        #expect(!String(decoding: data, as: UTF8.self).contains("\n"))
        #expect(try decoder.decode(ResponseHeader.self, from: data) == ResponseHeader(id: .int(7), ok: true, error: nil))
        #expect(try decoder.decode(Observation.self, from: data) == observation)
    }

    @Test func failureResponseShape() throws {
        let data = Wire.failure(id: .string("x"), .stale("Observation o-1 is outdated."))
        #expect(jsonObject(data) == jsonObject(#"{"id":"x","ok":false,"error":{"code":"stale","message":"Observation o-1 is outdated."}}"#))
        let header = try decoder.decode(ResponseHeader.self, from: data)
        #expect(header.error == DesktopError(.stale, "Observation o-1 is outdated."))
    }

    @Test func errorCodesMatchTheSpec() {
        #expect(ErrorCode.allCases.map(\.rawValue) == ["not_trusted", "stale", "not_found", "invalid", "failed", "not_supported", "not_permitted"])
        for code in ErrorCode.allCases {
            let data = Wire.failure(id: .null, DesktopError(code, "m"))
            #expect((jsonObject(data)["error"] as? NSDictionary)?["code"] as? String == code.rawValue)
        }
    }

    @Test func idsAreEchoedAsGiven() throws {
        for (raw, id) in [(#""abc""#, JSONValue.string("abc")), ("12", .int(12)), ("null", .null), ("1.5", .double(1.5)), ("true", .bool(true))] {
            let decoded = try decoder.decode(JSONValue.self, from: line(raw))
            #expect(decoded == id)
            #expect(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self) == raw)
        }
    }

    @Test func pingResultShape() {
        let data = Wire.success(id: .int(1), PingResult(trusted: false, screenRecording: true))
        #expect(jsonObject(data) == jsonObject(#"{"id":1,"ok":true,"trusted":false,"screenRecording":true,"version":"\#(handsDesktopVersion)"}"#))
    }

    @Test func slashesAndQuotesStayReadable() {
        let data = Wire.success(id: .int(1), ActResult(result: "Opened example.com/a", screenChanged: false))
        #expect(String(decoding: data, as: UTF8.self).contains("example.com/a"))
    }
}
