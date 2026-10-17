import ArgumentParser
import EyeballsKit
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check the install and, when the app runs, the store. Prints the permission rule to add.",
        discussion: "It exits 0 when the app is not running, unless you pass --strict. It never starts the app and never writes anything.")

    @Flag(help: "Exit 69 when the app is not running.")
    var strict = false

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let executable = AppBundle.executablePath()
            let info = Bundle.main.infoDictionary ?? [:]
            let cli = ComponentInfo(
                running: true,
                path: executable?.path,
                version: info["CFBundleShortVersionString"] as? String,
                build: info["CFBundleVersion"] as? String,
                protocolVersion: WireProtocol.version)
            var checks = DoctorChecks.local(
                home: Install.home,
                executable: executable,
                link: CommandLineToolLink.standard(debug: Install.isDebug))
            let (app, appChecks, failure) = askApp()
            checks += appChecks

            let report = DoctorReport(
                cli: cli,
                app: app,
                home: Install.home.root.path,
                socket: Install.home.socket.path,
                checks: checks,
                permissionRule: DoctorReport.permissionRule(commandName: Install.commandName),
                sandboxSetting: DoctorReport.sandboxSetting(socket: Install.home.socket.path))
            Output.printSuccess(result: try JSONValue(encoding: report), text: report.text, json: output.json)

            if let failure {
                Output.writeLine("eyeballs: " + TerminalText.escape(failure.message), to: .standardError)
                throw ExitCode(failure.code.exitStatus)
            }
            if !report.ok {
                let failed = checks.filter { $0.status == .failed }.count
                Output.writeLine("eyeballs: \(failed) doctor \(failed == 1 ? "check" : "checks") failed.", to: .standardError)
                throw ExitCode(ExitStatus.internalError)
            }
        }
    }

    /// What the app says about itself and its store. `failure` decides the exit status: an app
    /// that is not running fails only with `--strict`.
    private func askApp() -> (app: ComponentInfo, checks: [DoctorCheck], failure: EyeballsError?) {
        let absent = ComponentInfo(running: false, path: nil, version: nil, build: nil, protocolVersion: nil)
        do {
            let call = AppCall(operation: .doctor, agent: agent, start: .never, timeout: .seconds(5))
            switch try call.send(DoctorArguments()) {
            case .success(let result, _):
                let health = try result.decode(AppHealth.self)
                let app = ComponentInfo(running: true, path: health.path, version: health.version, build: health.build,
                                        protocolVersion: health.protocolVersion)
                let summary = DoctorCheck(name: "App", status: .passed,
                                          message: "Eyeballs \(health.version) (\(health.build)) is running from \(health.path).")
                return (app, [summary] + health.checks, nil)
            case .failure(let error):
                return (absent, [DoctorCheck(name: "App", status: .failed, message: error.message)], error)
            }
        } catch SocketClientError.notRunning {
            let message = "Eyeballs is not running, so the store was not checked."
            guard strict else { return (absent, [DoctorCheck(name: "App", status: .skipped, message: message)], nil) }
            let failure = EyeballsError(.appUnavailable, "Eyeballs is not running.", hint: "Open Eyeballs, then run eyeballs doctor again.")
            return (absent, [DoctorCheck(name: "App", status: .failed, message: message)], failure)
        } catch {
            let failure = EyeballsError(error)
            return (absent, [DoctorCheck(name: "App", status: .failed, message: failure.message)], failure)
        }
    }
}
