import XCTest
@testable import Assistant

@MainActor final class AlarmTests: XCTestCase {
    private func store(_ driver: FakeAlarms) -> NativeAlarms {
        let name = "AlarmTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return NativeAlarms(driver: driver, defaults: defaults)
    }
    private func row(_ id: UUID, version: Int = 1, at: Date = Date().addingTimeInterval(3600), enabled: Bool = true) -> [String: Any] {
        ["id": id.uuidString, "version": version, "title":"Prepare for the interview", "alarm_at":isoDate(at), "enabled":enabled]
    }
    func testRepeatedSyncSchedulesOnlyOnceAndConfirmsActualAlarm() async throws {
        let driver = FakeAlarms(); let store = store(driver); let id = UUID()
        var receipts: [[String: Any]] = []
        for _ in 0..<3 { try await store.sync([row(id)]) { receipts.append($0) } }
        XCTAssertEqual(driver.schedules, 1)
        XCTAssertEqual(receipts.last?["status"] as? String, "scheduled")
    }
    func testUnconfirmedSchedulingNeverReportsReady() async throws {
        let driver = FakeAlarms(); driver.keepScheduled = false
        let store = store(driver); let id = UUID()
        var result = ""
        try await store.sync([row(id)]) { result = $0["status"] as? String ?? "" }
        XCTAssertEqual(result, "failed")
        XCTAssertEqual(store.label(id.uuidString), "Alarm not scheduled — tap to retry")
    }
    func testSnoozeReplacesOldAlarmAndCompletionCancelsIt() async throws {
        let driver = FakeAlarms(); let store = store(driver); let id = UUID()
        try await store.sync([row(id)]) { _ in }
        try await store.sync([row(id,version:2)]) { _ in }
        XCTAssertEqual(driver.schedules,2); XCTAssertEqual(driver.cancels,1)
        try await store.sync([row(id,version:3,enabled:false)]) { _ in }
        XCTAssertEqual(driver.cancels,2); XCTAssertTrue(driver.ids.isEmpty)
    }
    func testDismissedAlarmDoesNotRearmAndPastAlarmDoesNotRingLate() async throws {
        let driver = FakeAlarms(); let store = store(driver); let id = UUID()
        try await store.sync([row(id)]) { _ in }
        driver.ids = []
        var status = ""
        try await store.sync([row(id)]) { status = $0["status"] as? String ?? "" }
        XCTAssertEqual(status,"dismissed"); XCTAssertEqual(driver.schedules,1)
        try await store.sync([row(UUID(),at:Date().addingTimeInterval(-10))]) { status = $0["status"] as? String ?? "" }
        XCTAssertEqual(status,"expired"); XCTAssertEqual(driver.schedules,1)
    }
    func testDeniedAndUnsupportedAreExplicit() async throws {
        let driver = FakeAlarms(); driver.allowed = false
        let store = store(driver); let id = UUID()
        var status = ""
        try await store.sync([row(id)]) { status = $0["status"] as? String ?? "" }
        XCTAssertEqual(status,"denied"); XCTAssertEqual(driver.schedules,0)
        driver.supported = false
        try await store.sync([row(id)]) { status = $0["status"] as? String ?? "" }
        XCTAssertEqual(status,"unsupported"); XCTAssertEqual(driver.schedules,0)
    }
    func testReceiptFailureRetriesWithoutSchedulingAgain() async throws {
        let driver = FakeAlarms(); let store = store(driver); let id = UUID()
        do { try await store.sync([row(id)]) { _ in throw URLError(.notConnectedToInternet) }; XCTFail("Expected failure") }
        catch {}
        try await store.sync([row(id)]) { _ in }
        XCTAssertEqual(driver.schedules,1)
    }
    func testOfflineSnoozeAndStopAreIdempotent() async throws {
        let driver = FakeAlarms(); let store = store(driver); let id = UUID()
        try await store.sync([row(id)]) { _ in }
        let args: [String: Any] = ["id":id.uuidString,"version":1,"action":"snooze","until":isoDate(Date().addingTimeInterval(7200))]
        for _ in 0..<2 { try await store.applyAction(args,title:"Prep") }
        XCTAssertEqual(driver.schedules,2)
        try await store.applyAction(["id":id.uuidString,"version":2,"action":"done"],title:"Prep")
        XCTAssertTrue(driver.ids.isEmpty)
    }
}

@MainActor private final class FakeAlarms: AlarmScheduling {
    var supported = true
    var allowed = true
    var keepScheduled = true
    var ids = Set<UUID>()
    var schedules = 0
    var cancels = 0
    func authorize() async throws -> Bool { allowed }
    func current() throws -> Set<UUID> { ids }
    func schedule(id: UUID, title: String, at: Date) async throws { schedules += 1; if keepScheduled { ids.insert(id) } }
    func cancel(id: UUID) throws { cancels += 1; ids.remove(id) }
}
