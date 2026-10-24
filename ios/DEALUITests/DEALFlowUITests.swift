import XCTest

/// End-to-end smoke tests against a running backend in mock mode (`cd backend && npm run dev`).
/// Each test drives one phone through the UI and plays the other phone over the HTTP API (Section 12.5).
///
///   xcodebuild test -project DEAL.xcodeproj -scheme DEAL \
///     -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
///     TEST_RUNNER_DEAL_SHOT_DIR=/some/dir    # optional: also write PNG screenshots there
///
/// Screenshots are always attached to the .xcresult as well.
final class DEALFlowUITests: XCTestCase {
    private let base = URL(string: ProcessInfo.processInfo.environment["DEAL_BACKEND_URL"] ?? "http://127.0.0.1:3000")!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: Buyer phone (UI) + seller via API

    func testBuyerFlow() throws {
        button(startingWith: "I'm Buying").tapWhenReady()
        shot("B2-new-negotiation")
        app.buttons["Use demo values"].tapWhenReady()
        let existing = Set(try sessionIDs())
        let start = app.buttons["Start Session"]
        if !start.waitForExistence(timeout: 3) || !start.isHittable { app.swipeUp() }
        start.tapWhenReady()

        // The join-code sheet opens automatically on first entry to B3.
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 5) {
            shot("B3-join-code")
            done.tap()
        }

        var sid = ""
        waitUntil(timeout: 15) {
            guard let new = (try? self.sessionIDs())?.first(where: { !existing.contains($0) }) else { return false }
            sid = new
            return true
        }
        let play = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Play'")).firstMatch
        play.tapWhenReady()
        waitUntil(timeout: 60) { (try? self.state(sid)["events"] as? [Any])?.count ?? 0 >= 8 }
        shot("B3-live-mid-script")
        waitUntil(timeout: 120) { ((try? self.state(sid)["script"] as? [String: Any])?["done"] as? Bool) == true }
        sleep(2)
        shot("B3-live-script-done")

        app.buttons["Lock Deal"].tapWhenReady()
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Confirm'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "B4 Confirm button never appeared")
        shot("B4-agreement-review")
        confirm.tap()

        // Seller confirms on "their phone".
        let agreementID = try XCTUnwrap((try state(sid)["agreement"] as? [String: Any])?["id"] as? String)
        _ = try api("POST", "/agreements/\(agreementID)/confirm", ["role": "seller"])
        sleep(3)
        shot("B4-agreement-locked")

        // Seller tries to add the $1,200 protection package -> blocked -> B5.
        let blocked = try api("POST", "/sessions/\(sid)/payment-requests", ["line_items": [
            ["label": "2023 Honda Accord EX", "amount": 3_460_000],
            ["label": "floor mats", "amount": 0],
            ["label": "doc fee", "amount": 0],
            ["label": "protection package", "amount": 120_000],
        ]])
        XCTAssertEqual(blocked["status"] as? String, "blocked")
        let reject = app.buttons["Reject"]
        XCTAssertTrue(reject.waitForExistence(timeout: 15), "B5 charge alert never appeared")
        sleep(1)
        shot("B5-charge-alert")
        reject.tap()
        sleep(2)
        XCTAssertEqual(try (state(sid)["payment_requests"] as? [[String: Any]])?.first?["status"] as? String, "rejected")

        // Seller charges the agreed amount.
        let ok = try api("POST", "/sessions/\(sid)/payment-requests", ["line_items": [
            ["label": "2023 Honda Accord EX", "amount": 3_460_000],
            ["label": "floor mats", "amount": 0],
            ["label": "doc fee", "amount": 0],
        ]])
        XCTAssertEqual(ok["status"] as? String, "approved")
        _ = try api("POST", "/payment-requests/\(try XCTUnwrap(ok["id"] as? String))/pay")
        XCTAssertTrue(app.staticTexts["Payment complete"].waitForExistence(timeout: 15), "B6 receipt never appeared")
        sleep(1)
        shot("B6-receipt")
    }

    // MARK: Seller phone (UI) + buyer via API

    func testSellerFlow() throws {
        let session = try api("POST", "/sessions", [
            "category": "car", "item": "2023 Honda Accord EX", "asking_price": 3_800_000,
            "target_price": 3_450_000, "max_budget": 3_600_000, "style": "firm",
        ])
        let sid = try XCTUnwrap(session["id"] as? String)
        let code = try XCTUnwrap(session["join_code"] as? String)

        button(startingWith: "I'm Selling").tapWhenReady()
        let field = app.textFields["Join code"]
        field.tapWhenReady()
        field.typeText(code)
        shot("S1-join")
        app.buttons["Join"].tapWhenReady()

        _ = try api("POST", "/sessions/\(sid)/script/play", ["script_id": "car_accord", "interval_ms": 250])
        waitUntil(timeout: 60) { ((try? self.state(sid)["script"] as? [String: Any])?["done"] as? Bool) == true }
        sleep(2)
        shot("S2-live-view")

        let agreement = try api("POST", "/sessions/\(sid)/agreement")
        _ = try api("POST", "/agreements/\(try XCTUnwrap(agreement["id"] as? String))/confirm", ["role": "buyer"])
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Confirm'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "S3 Confirm never appeared")
        shot("S3-agreement")
        confirm.tap()

        XCTAssertTrue(app.staticTexts["DEAL Terminal"].waitForExistence(timeout: 15), "S4 terminal never appeared")
        sleep(1)
        shot("S4-terminal")

        app.buttons["Add line item"].tapWhenReady()
        let label = app.textFields["Label"]
        label.tapWhenReady()
        label.typeText("protection package")
        let amount = app.textFields["Amount"]
        amount.tap()
        amount.typeText("1200")
        shot("S4-add-line-item")
        app.buttons["Add"].tapWhenReady()

        XCTAssertTrue(app.staticTexts["Waiting for buyer approval"].waitForExistence(timeout: 15), "terminal never showed waiting state")
        shot("S4-waiting-for-buyer")
        let blocked = try XCTUnwrap((try state(sid)["payment_requests"] as? [[String: Any]])?.first { $0["status"] as? String == "blocked" })
        _ = try api("POST", "/payment-requests/\(try XCTUnwrap(blocked["id"] as? String))/decision", ["decision": "reject"])

        XCTAssertTrue(app.staticTexts["Buyer rejected the change"].waitForExistence(timeout: 15))
        shot("S4-rejected")
        app.buttons["Tap to Pay"].tapWhenReady()
        sleep(1)
        shot("S4-tap-presenting")
        XCTAssertTrue(app.staticTexts["Payment complete"].waitForExistence(timeout: 20), "S5 receipt never appeared")
        sleep(1)
        shot("S5-receipt")
        XCTAssertNotNil(try state(sid)["receipt"] as? [String: Any])
    }

    // MARK: Helpers

    private func button(startingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["DEAL_SHOT_DIR"] {
            let prefix = name.hasPrefix("S") ? "seller" : "buyer"
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)-\(name).png"))
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("Timed out after \(timeout)s")
    }

    private func sessionIDs() throws -> [String] {
        var request = URLRequest(url: base.appendingPathComponent("sessions"))
        request.httpMethod = "GET"
        let list = try XCTUnwrap(try send(request) as? [[String: Any]])
        return list.compactMap { $0["id"] as? String }
    }

    private func state(_ sid: String) throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent("sessions/\(sid)"))
        request.httpMethod = "GET"
        return try XCTUnwrap(try send(request) as? [String: Any])
    }

    @discardableResult
    private func api(_ method: String, _ path: String, _ body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try XCTUnwrap(try send(request) as? [String: Any], "\(method) \(path)")
    }

    private func send(_ request: URLRequest) throws -> Any {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(URLError(.timedOut))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(NSError(domain: "DEALAPI", code: http.statusCode,
                                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data ?? Data(), as: UTF8.self)]))
            } else { result = .success(data ?? Data()) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        return try JSONSerialization.jsonObject(with: try result.get())
    }
}

private extension XCUIElement {
    func tapWhenReady(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(self) not found", file: file, line: line)
        tap()
    }
}
