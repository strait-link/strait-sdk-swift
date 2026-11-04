import XCTest
@testable import StraitSDK

/// Contract B6a (shared-spec ADR 0003), port of sdk-react-native/test/install-state.test.ts:
/// storage restored from a backup of another install (a restored iPhone) must not skip the
/// once-per-install deferred check.

private let T_OLD: Double = 1_780_000_000_000
private let T_NEW: Double = 1_790_000_000_000
private let noMatch: [String: Any] = ["matched": false]

final class FirstLaunchStateTests: XCTestCase {
    func testNormalLaunchUpgradeRestoreAndFirstLaunch() {
        XCTAssertEqual(firstLaunchState(flag: "1", stored: "1790000000000", installTime: T_NEW),
                       FirstLaunchState(firstLaunch: false, clearFlag: false, storeInstallTime: nil))
        XCTAssertEqual(firstLaunchState(flag: "1", stored: nil, installTime: T_NEW),
                       FirstLaunchState(firstLaunch: false, clearFlag: false, storeInstallTime: "1790000000000"))
        XCTAssertEqual(firstLaunchState(flag: "1", stored: "1780000000000", installTime: T_NEW),
                       FirstLaunchState(firstLaunch: true, clearFlag: true, storeInstallTime: "1790000000000"))
        XCTAssertEqual(firstLaunchState(flag: nil, stored: nil, installTime: T_NEW),
                       FirstLaunchState(firstLaunch: true, clearFlag: false, storeInstallTime: "1790000000000"))
        XCTAssertEqual(firstLaunchState(flag: "1", stored: "1780000000000", installTime: nil),
                       FirstLaunchState(firstLaunch: false, clearFlag: false, storeInstallTime: nil))
    }

    func testOutOfRangeInstallTimeIsUnknownNotACrash() {
        for t in [Double.nan, .infinity, -.infinity, 1e300] {
            XCTAssertEqual(firstLaunchState(flag: "1", stored: "1780000000000", installTime: t),
                           FirstLaunchState(firstLaunch: false, clearFlag: false, storeInstallTime: nil), "\(t)")
        }
    }
}

final class InstallTimeStartTests: XCTestCase {
    private func store(_ initial: [String: String] = [:]) -> MemoryStorage {
        let s = MemoryStorage()
        initial.forEach { s.setItem($0.key, $0.value) }
        return s
    }

    private func launch(_ storage: MemoryStorage, _ engine: FakeEngine, installTime: @escaping () -> Double?) -> Harness {
        let h = Harness(engine, storage: storage, installTime: installTime)
        h.start()
        return h
    }

    func testRestoredStorageRunsTheCheckAgainOnceAndCountsTheInstall() throws {
        let s = store(["strait.deferredChecked": "1", "strait.installTime": "1780000000000"])
        let engine = FakeEngine(["/v1/match": noMatch])
        let h = launch(s, engine) { T_NEW }
        XCTAssertEqual(engine.calls(to: "/v1/match").count, 1)
        let openId = try XCTUnwrap(engine.calls(to: "/v1/match").first?.body?["openId"] as? String)
        XCTAssertTrue(openId.hasPrefix("o_"), openId)
        XCTAssertEqual(h.events.map(\.kind), [.deferred])
        XCTAssertEqual(s.getItem("strait.deferredChecked"), "1")
        XCTAssertEqual(s.getItem("strait.installTime"), "1790000000000")
        // and only once: the next launch is a normal one
        _ = launch(s, engine) { T_NEW }
        XCTAssertEqual(engine.calls(to: "/v1/match").count, 1)
    }

    func testAppUpdatedFromAnOlderSDKAdoptsTheTimeWithoutANewInstall() {
        let s = store(["strait.deferredChecked": "1"])
        let engine = FakeEngine(["/v1/match": noMatch])
        let h = launch(s, engine) { T_NEW }
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(engine.calls(to: "/v1/match").isEmpty)
        XCTAssertEqual(s.getItem("strait.installTime"), "1790000000000")
    }

    func testRestoredStorageOfflineFirstLaunchRetriesNextLaunch() {
        let s = store(["strait.deferredChecked": "1", "strait.installTime": "1780000000000"])
        let offline = FakeEngine()
        offline.modes["/v1/match"] = .offline
        _ = launch(s, offline) { T_NEW }
        XCTAssertEqual(s.getItem("strait.deferredChecked"), "")
        let engine = FakeEngine(["/v1/match": noMatch])
        _ = launch(s, engine) { T_NEW }
        XCTAssertEqual(engine.calls(to: "/v1/match").count, 1)
        XCTAssertEqual(s.getItem("strait.deferredChecked"), "1")
    }

    func testUnknownOrInvalidInstallTimeBehavesAsBefore() {
        for t: Double? in [nil, 0, -5, .nan] {
            let s = store(["strait.deferredChecked": "1", "strait.installTime": "1780000000000"])
            let engine = FakeEngine(["/v1/match": noMatch])
            _ = launch(s, engine) { t }
            XCTAssertTrue(engine.calls(to: "/v1/match").isEmpty, String(describing: t))
            XCTAssertEqual(s.getItem("strait.installTime"), "1780000000000", String(describing: t))
        }
    }

    func testFreshInstallStoresItsInstallTimeWithTheFlag() {
        let s = store()
        let engine = FakeEngine(["/v1/match": noMatch])
        _ = launch(s, engine) { T_NEW }
        XCTAssertEqual(engine.calls(to: "/v1/match").count, 1)
        XCTAssertEqual(s.getItem("strait.installTime"), "1790000000000")
        XCTAssertEqual(s.getItem("strait.deferredChecked"), "1")
    }

    func testRestoredStorageOpenedByALinkCountsAsTheInstallsFirstOpen() throws {
        let s = store(["strait.deferredChecked": "1", "strait.installTime": "1780000000000"])
        let engine = FakeEngine(["/v1/open": ["ok": true]])
        let h = Harness(engine, storage: s, installTime: { T_NEW })
        h.start("straitlink://shop.example/p/42")
        XCTAssertTrue(engine.calls(to: "/v1/match").isEmpty, "launched by a link: no deferred check")
        XCTAssertEqual(engine.calls(to: "/v1/open").last?.body?["firstLaunch"] as? Bool, true)
        XCTAssertEqual(s.getItem("strait.deferredChecked"), "1")
    }
}

/// The default `installTime`: a marker file in a backup-excluded folder (B6a). Tests use a temp
/// directory, never the runner's real Application Support.
final class InstallMarkerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("strait-marker-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCreatesTheMarkerOnceAndReusesIt() throws {
        let before = Date().timeIntervalSince1970 * 1000
        let first = try XCTUnwrap(StraitLinksConfig.markerInstallTime(in: dir))
        XCTAssertEqual(first, first.rounded(.down), "whole ms")
        XCTAssertGreaterThanOrEqual(first, before.rounded(.down) - 1000)
        let file = dir.appendingPathComponent("Strait/install-time")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(StraitLinksConfig.markerInstallTime(in: dir), first, "same marker, same time")
    }

    func testTheFolderIsExcludedFromBackup() throws {
        _ = try XCTUnwrap(StraitLinksConfig.markerInstallTime(in: dir))
        let folder = URL(fileURLWithPath: dir.appendingPathComponent("Strait", isDirectory: true).path)
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testARestoreWithoutTheMarkerGetsANewTime() throws {
        let first = try XCTUnwrap(StraitLinksConfig.markerInstallTime(in: dir))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Strait/install-time"))
        Thread.sleep(forTimeInterval: 0.02)
        let second = try XCTUnwrap(StraitLinksConfig.markerInstallTime(in: dir))
        XCTAssertGreaterThan(second, first)
    }

    func testUnwritableLocationIsUnknown() throws {
        let blocker = dir.appendingPathComponent("file")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        XCTAssertNil(StraitLinksConfig.markerInstallTime(in: blocker))
    }
}
