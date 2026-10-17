import ArgumentParser
import EyeballsKit
import Foundation

/// Prints results the way every command must: exactly one document on stdout, text by default
/// or JSON with `--json`, and one human line on stderr for an error.
enum Output {
    static func printSuccess(result: JSONValue, text: String, json: Bool) {
        if json {
            writeLine(result.serialized())
        } else if !text.isEmpty {
            writeLine(TerminalText.escape(text))
        }
    }

    /// The stderr line is the message. Stdout gets the error document with `--json`, and the
    /// hint as text without it.
    static func printFailure(_ error: EyeballsError, json: Bool) {
        writeLine("eyeballs: " + TerminalText.escape(error.message), to: .standardError)
        if json {
            writeLine((try? JSONValue(encoding: ErrorDocument(error: error)).serialized()) ?? "")
        } else if let hint = error.hint, !hint.isEmpty {
            writeLine(TerminalText.escape(hint))
        }
    }

    /// Writes straight to the descriptor, so a monitor reading `watch` through a pipe sees
    /// each line at once rather than when a buffer fills.
    static func writeLine(_ text: String, to handle: FileHandle = .standardOutput) {
        let line = text.hasSuffix("\n") ? text : text + "\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

extension Response.Outcome {
    /// Prints a success. Prints a failure and throws its exit status.
    func print(json: Bool) throws {
        switch self {
        case .success(let result, let text):
            Output.printSuccess(result: result, text: text, json: json)
        case .failure(let error):
            Output.printFailure(error, json: json)
            throw ExitCode(error.code.exitStatus)
        }
    }
}

/// Runs a command's work, printing any error as `Output` describes and exiting with the status
/// its code maps to. Usage errors pass through, so swift-argument-parser prints the usage and
/// exits 64.
func reportingErrors(json: Bool, _ work: () throws -> Void) throws {
    do {
        try work()
    } catch let error as ExitCode {
        throw error
    } catch let error as ValidationError {
        throw error
    } catch {
        let failure = EyeballsError(error)
        Output.printFailure(failure, json: json)
        throw ExitCode(failure.code.exitStatus)
    }
}
