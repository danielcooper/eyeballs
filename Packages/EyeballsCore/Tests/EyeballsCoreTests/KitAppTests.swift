import Darwin
import EyeballsKit
import Foundation
import Testing

struct KitAppBundleTests {
    @Test func findsTheAppAroundItsHelper() {
        let helper = URL(fileURLWithPath: "/Applications/Eyeballs.app/Contents/Helpers/eyeballs")
        #expect(AppBundle.containing(helper: helper)?.path == "/Applications/Eyeballs.app")
    }

    @Test(arguments: [
        "/usr/local/bin/eyeballs",
        "/Applications/Eyeballs.app/Contents/MacOS/eyeballs",
        "/Applications/Eyeballs/Contents/Helpers/eyeballs",
        "/Applications/Eyeballs.app/Helpers/eyeballs",
    ])
    func findsNoAppAnywhereElse(path: String) {
        #expect(AppBundle.containing(helper: URL(fileURLWithPath: path)) == nil)
    }

    @Test func resolvesItsOwnExecutable() throws {
        let path = try #require(AppBundle.executablePath())
        #expect(FileManager.default.isExecutableFile(atPath: path.path))
        #expect(path.path == path.resolvingSymlinksInPath().path)
    }

    @Test func readsABundleIdentifier() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let app = try makeApp(in: folder.url, name: "Eyeballs", identifier: "coops.eyeballs")
        #expect(AppBundle.identifier(of: app) == "coops.eyeballs")
        #expect(AppBundle.identifier(of: folder.url) == nil)
    }
}

@Suite(.serialized)
struct KitAppConnectorTests {
    @Test func failsAtOnceWhenItMayNotStartTheApp() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        var connector = AppConnector(home: folder.home, app: URL(fileURLWithPath: "/Applications/Eyeballs.app"))
        connector.launch = { _, _ in Issue.record("It must not start the app") }
        #expect(throws: SocketClientError.notRunning) { _ = try connector.connect(start: .never) }
        #expect(ExitStatus.forError(SocketClientError.notRunning) == 69)
    }

    @Test func startsTheAppInTheBackgroundThenRetries() async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let server = SocketServer(home: folder.home, handler: FakeHandler.echo())
        defer { server.stop() }
        let launches = Recorder<Bool>()

        var connector = AppConnector(home: folder.home, app: URL(fileURLWithPath: "/Applications/Eyeballs.app"))
        connector.launch = { app, inFront in
            #expect(app.path == "/Applications/Eyeballs.app")
            launches.append(inFront)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { try? server.start(holdingInstanceLock: true) }
        }
        let started = ContinuousClock.now
        let ready = connector
        let response = try await offPool {
            let client = try ready.connect(start: .inBackground)
            return try client.exchange(try request(.inbox), timeout: .seconds(5))
        }
        #expect(response.successText == "did inbox")
        #expect(launches.values == [false])
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func bringsTheAppToTheFrontEvenWhenItRuns() async throws {
        try await withServer(FakeHandler.echo()) { _, home in
            let launches = Recorder<Bool>()
            var connector = AppConnector(home: home, app: URL(fileURLWithPath: "/Applications/Eyeballs.app"))
            connector.launch = { _, inFront in launches.append(inFront) }
            let ready = connector
            _ = try await offPool { ClientBox(try ready.connect(start: .inFront)) }
            #expect(launches.values == [true])
        }
    }

    @Test func givesUpWhenTheAppNeverAnswers() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        var connector = AppConnector(home: folder.home, app: URL(fileURLWithPath: "/Applications/Eyeballs.app"))
        connector.startupTimeout = .milliseconds(400)
        connector.launch = { _, _ in }
        do {
            _ = try connector.connect(start: .inBackground)
            Issue.record("Expected app_unavailable")
        } catch let error as EyeballsError {
            #expect(error.code == .appUnavailable)
            #expect(error.message == "Eyeballs did not start within 1 s.")
        }
    }

    @Test func saysWhyItCannotStartAnAppItCannotFind() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let connector = AppConnector(home: folder.home, app: nil)
        do {
            _ = try connector.connect(start: .inBackground)
            Issue.record("Expected app_unavailable")
        } catch let error as EyeballsError {
            #expect(error.code == .appUnavailable)
            #expect(error.message.contains("not inside Eyeballs.app"))
        }
    }
}

struct KitCommandLineToolLinkTests {
    @Test func installsAndReplacesItsLink() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let link = CommandLineToolLink(folder: folder.url.appendingPathComponent("bin"), name: "eyeballs")
        #expect(link.state == .missing)
        try link.install(pointingTo: URL(fileURLWithPath: "/Applications/Eyeballs.app/Contents/Helpers/eyeballs"))
        #expect(link.state == .link(to: "/Applications/Eyeballs.app/Contents/Helpers/eyeballs"))
        try link.install(pointingTo: URL(fileURLWithPath: "/Applications/Other.app/Contents/Helpers/eyeballs"))
        #expect(link.state == .link(to: "/Applications/Other.app/Contents/Helpers/eyeballs"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: link.folder.path) == ["eyeballs"])
    }

    @Test func neverReplacesAFileThatIsNotALink() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let link = CommandLineToolLink(folder: folder.url, name: "eyeballs")
        try Data("#!/bin/sh\n".utf8).write(to: link.path)
        #expect(link.state == .notALink)
        #expect(throws: EyeballsError.self) { try link.install(pointingTo: URL(fileURLWithPath: "/x")) }
        #expect(try link.repairIfNeeded(helper: URL(fileURLWithPath: "/x"), expectedIdentifier: "coops.eyeballs") == .unchanged)
        #expect(try String(contentsOf: link.path, encoding: .utf8) == "#!/bin/sh\n")
    }

    @Test func repairsALinkIntoAMissingOrForeignBundle() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let release = try makeApp(in: folder.url, name: "Eyeballs", identifier: "coops.eyeballs")
        let debug = try makeApp(in: folder.url, name: "Eyeballs Debug", identifier: "coops.eyeballs.debug")
        let helper = release.appendingPathComponent("Contents/Helpers/eyeballs")
        let link = CommandLineToolLink(folder: folder.url.appendingPathComponent("bin"), name: "eyeballs")
        try FileManager.default.createDirectory(at: link.folder, withIntermediateDirectories: true)

        try link.install(pointingTo: debug.appendingPathComponent("Contents/Helpers/eyeballs"))
        #expect(try link.repairIfNeeded(helper: helper, expectedIdentifier: "coops.eyeballs") == .repaired)
        #expect(link.state == .link(to: helper.path))

        try link.install(pointingTo: folder.url.appendingPathComponent("Gone.app/Contents/Helpers/eyeballs"))
        #expect(try link.repairIfNeeded(helper: helper, expectedIdentifier: "coops.eyeballs") == .repaired)
        #expect(link.state == .link(to: helper.path))

        #expect(try link.repairIfNeeded(helper: helper, expectedIdentifier: "coops.eyeballs") == .unchanged)

        try link.install(pointingTo: URL(fileURLWithPath: "/usr/local/libexec/eyeballs-dev"))
        #expect(try link.repairIfNeeded(helper: helper, expectedIdentifier: "coops.eyeballs") == .unchanged)
    }

    @Test func leavesAMissingLinkMissing() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let link = CommandLineToolLink(folder: folder.url, name: "eyeballs")
        #expect(try link.repairIfNeeded(helper: URL(fileURLWithPath: "/x"), expectedIdentifier: "coops.eyeballs") == .unchanged)
        #expect(link.state == .missing)
    }

    @Test func debugBuildsUseTheirOwnName() {
        #expect(CommandLineToolLink.standard(debug: true).name == "eyeballs-debug")
        #expect(CommandLineToolLink.standard(debug: false).path.path.hasSuffix("/.local/bin/eyeballs"))
    }
}

struct KitTextInputTests {
    @Test func readsAFile() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let file = folder.url.appendingPathComponent("note.txt")
        try Data("Moved money to Decimal.\n".utf8).write(to: file)
        #expect(try TextInput.read(file.path, option: "--note-file", limit: 100) == "Moved money to Decimal.\n")
    }

    @Test func refusesLargeMissingAndNonUTF8Files() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let large = folder.url.appendingPathComponent("large")
        try Data(repeating: 65, count: 2048).write(to: large)
        let binary = folder.url.appendingPathComponent("binary")
        try Data([0xFF, 0xFE, 0xFD]).write(to: binary)
        let secretPath = folder.url.appendingPathComponent("secret-name").path

        for (path, expected) in [(large.path, "over the 1 KB limit"), (binary.path, "not UTF-8"), (secretPath, "cannot be read")] {
            do {
                _ = try TextInput.read(path, option: "--body-file", limit: 1024)
                Issue.record("Expected bad_input")
            } catch let error as EyeballsError {
                #expect(error.code == .badInput)
                #expect(error.message.contains(expected), "\(error.message)")
                #expect(error.message.contains("--body-file"))
                #expect(!error.message.contains("secret-name"))
            }
        }
    }
}

struct KitDoctorCheckTests {
    @Test func anEmptyHomePasses() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let link = CommandLineToolLink(folder: folder.url.appendingPathComponent("bin"), name: "eyeballs")
        let helper = URL(fileURLWithPath: "/Applications/Eyeballs.app/Contents/Helpers/eyeballs")
        let checks = DoctorChecks.local(home: folder.home, executable: helper, link: link, searchPath: "/usr/bin:\(link.folder.path)")
        #expect(checks.map(\.name) == ["Command", "Home folder", "Run folder", "Socket path", "Command link", "PATH"])
        #expect(!checks.contains { $0.status == .failed })
        #expect(checks.first { $0.name == "Command link" }?.status == .warning)
        #expect(checks.first { $0.name == "PATH" }?.status == .passed)
    }

    @Test func anOpenFolderFails() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        try folder.home.prepare()
        chmod(folder.home.run.path, 0o755)
        let link = CommandLineToolLink(folder: folder.url, name: "eyeballs")
        let checks = DoctorChecks.local(home: folder.home, executable: nil, link: link, searchPath: "")
        let run = try #require(checks.first { $0.name == "Run folder" })
        #expect(run.status == .failed)
        #expect(run.message.contains("755"))
        #expect(checks.first { $0.name == "Home folder" }?.status == .passed)
        #expect(checks.first { $0.name == "PATH" }?.status == .warning)
    }

    @Test func aLinkToThisCommandPasses() throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let helper = folder.url.appendingPathComponent("eyeballs-helper")
        try Data().write(to: helper)
        let link = CommandLineToolLink(folder: folder.url.appendingPathComponent("bin"), name: "eyeballs")
        try link.install(pointingTo: helper)
        let check = DoctorChecks.local(home: folder.home, executable: helper, link: link).first { $0.name == "Command link" }
        #expect(check?.status == .passed)
    }

    @Test func theReportCountsFailures() {
        let failed = DoctorCheck(name: "Run folder", status: .failed, message: "x")
        let none = ComponentInfo(running: false, path: nil, version: nil, build: nil, protocolVersion: nil)
        let report = DoctorReport(cli: none, app: none, home: "/h", socket: "/h/run/eyeballs.sock", checks: [failed],
                                  permissionRule: "Bash(eyeballs *)", sandboxSetting: "s")
        #expect(!report.ok)
        #expect(report.text.contains("FAIL  Run folder: x"))
        #expect(report.text.contains("  \"Bash(eyeballs *)\""))
    }
}

/// A minimal `.app` folder with an `Info.plist` and a helper.
func makeApp(in folder: URL, name: String, identifier: String) throws -> URL {
    let app = folder.appendingPathComponent("\(name).app", isDirectory: true)
    let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    try Data().write(to: helpers.appendingPathComponent("eyeballs"))
    return app
}
