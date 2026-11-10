import ArgumentParser
import Foundation
import MahoNotesKit

/// The CLI's version: `mn --version` and the `version` field of `mn skill --json`.
/// Keep in sync with `MARKETING_VERSION` in App/project.yml and the README badge.
let mnVersion = "1.0.4"

// MARK: - Runtime state

enum CLIRuntime {
    /// True once a command has parsed `--json`. Errors are then reported as JSON too.
    nonisolated(unsafe) static var jsonOutput = false
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

// MARK: - Errors

/// A failure with a stable `code`, so an agent can branch on it instead of parsing prose.
struct CLIError: Error {
    var code: String
    var message: String
    var hint: String?
    var suggestions: [String] = []
    /// Process exit status. 1 for failures; 64 for arguments ArgumentParser rejected.
    var exitStatus: Int32 = EXIT_FAILURE

    init(code: String, message: String, hint: String? = nil, suggestions: [String] = []) {
        self.code = code
        self.message = message
        self.hint = hint
        self.suggestions = suggestions
    }

    init(_ error: NoteError) {
        self.init(
            code: error.code,
            message: error.errorDescription ?? "\(error)",
            hint: error.hint,
            suggestions: error.suggestions
        )
    }
}

private struct ErrorEnvelope: Encodable {
    struct Body: Encodable {
        let code: String
        let message: String
        let hint: String?
        let suggestions: [String]?
    }
    let error: Body
}

extension MahoNotes {
    /// Report a failure and exit.
    ///
    /// With `--json` the error goes to stdout as `{"error": {"code", "message", "hint", "suggestions"}}`
    /// so the caller's JSON parser sees it; otherwise it goes to stderr as text. Exit status is
    /// non-zero either way (64 for arguments that could not be parsed, as ArgumentParser uses).
    /// Help and version output, and usage errors without `--json`, keep ArgumentParser's handling.
    static func report(_ error: Error) -> Never {
        // A usage error is thrown before any command's `--json` flag has been parsed,
        // so also look for the flag in the raw arguments.
        let jsonOutput = CLIRuntime.jsonOutput || CommandLine.arguments.dropFirst().contains("--json")
        let cliError: CLIError?
        if let error = error as? CLIError {
            cliError = error
        } else if let error = error as? NoteError {
            cliError = CLIError(error)
        } else if jsonOutput, !(error is CleanExit), !(error is ExitCode),
                  exitCode(for: error) != .success {
            // Anything else thrown while running in JSON mode still gets a JSON envelope.
            let status = exitCode(for: error)
            var wrapped = CLIError(
                code: status == .validationFailure ? "invalid_arguments" : "error",
                message: message(for: error)
            )
            wrapped.exitStatus = status.rawValue
            cliError = wrapped
        } else {
            cliError = nil
        }

        guard let cliError else {
            exit(withError: error)
        }

        if jsonOutput {
            let envelope = ErrorEnvelope(error: .init(
                code: cliError.code,
                message: cliError.message,
                hint: cliError.hint,
                suggestions: cliError.suggestions.isEmpty ? nil : cliError.suggestions
            ))
            if (try? printJSON(envelope)) == nil {
                print(#"{"error":{"code":"error","message":"failed to encode error"}}"#)
            }
        } else {
            printError("Error: \(cliError.message)")
            if !cliError.suggestions.isEmpty {
                printError("Did you mean:")
                for suggestion in cliError.suggestions {
                    printError("  \(suggestion)")
                }
            } else if let hint = cliError.hint {
                printError(hint)
            }
        }
        Foundation.exit(cliError.exitStatus)
    }
}

// MARK: - JSON shapes

/// A note in JSON output. Same keys as `Note`, with the body optional — lists leave it
/// out so reading a vault's index does not cost the whole vault's text.
struct NoteOutput: Encodable {
    let relativePath: String
    let title: String
    let collection: String
    let tags: [String]
    let created: String
    let updated: String
    let isPublic: Bool
    let slug: String?
    let author: String?
    let draft: Bool
    let order: Int?
    let series: String?
    let body: String?
    let vaultName: String?
    let absolutePath: String?

    init(_ note: Note, includeBody: Bool, absolutePath: String? = nil) {
        relativePath = note.relativePath
        title = note.title
        collection = note.collection
        tags = note.tags
        created = note.created
        updated = note.updated
        isPublic = note.isPublic
        slug = note.slug
        author = note.author
        draft = note.draft
        order = note.order
        series = note.series
        body = includeBody ? note.body : nil
        vaultName = note.vaultName
        self.absolutePath = absolutePath
    }
}

/// Result of a command that changes a note.
struct NoteActionOutput: Encodable {
    /// created, exists, replaced, appended, edited, updated, moved, trashed or deleted.
    let action: String
    /// Vault-relative path of the note after the action.
    let path: String
    let absolutePath: String?
    /// Previous path, for `moved`.
    var from: String?
    /// Number of replacements, for `edited`.
    var replacements: Int?
    /// The note's metadata after the action (never its body).
    var note: NoteOutput?
}

extension Vault {
    /// Metadata of a note for an action result; nil when the file cannot be parsed.
    func noteOutput(_ relativePath: String, includeBody: Bool = false) -> NoteOutput? {
        guard let note = try? parseNote(at: absolutePath(for: relativePath), relativeTo: path) else { return nil }
        return NoteOutput(note, includeBody: includeBody)
    }
}

// MARK: - Body input

/// `--body` / `--stdin` / `--file`: the three ways to hand note text to a command.
struct BodyInput: ParsableArguments {
    // `.unconditional`: the next argument is always the value, so Markdown that starts
    // with a dash (`--body "- item"`) is not mistaken for another option.
    @Option(
        name: .long,
        parsing: .unconditional,
        help: "Body text (Markdown). For multi-line text, --stdin with a heredoc is easier to get right."
    )
    var body: String?

    @Flag(name: .long, help: "Read the body from standard input")
    var stdin = false

    @Option(name: .long, help: ArgumentHelp("Read the body from a file", valueName: "path"))
    var file: String?

    func validate() throws {
        let given = [body != nil, stdin, file != nil].filter { $0 }.count
        if given > 1 {
            throw ValidationError("Pass only one of --body, --stdin and --file.")
        }
    }

    /// The body text, or nil when none of the three was given.
    func read() throws -> String? {
        if let body { return body }
        if stdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                throw CLIError(code: "invalid_input", message: "Standard input is not valid UTF-8 text")
            }
            return text
        }
        if let file {
            let path = (file as NSString).expandingTildeInPath
            do {
                return try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw CLIError(
                    code: "invalid_input",
                    message: "Cannot read body file \(file): \(error.localizedDescription)"
                )
            }
        }
        return nil
    }
}

// MARK: - Dates

/// Parse a frontmatter timestamp for sorting. Notes carry several spellings
/// (`…+08:00`, `…Z`, date only), so comparing the strings would misorder them.
func parseNoteDate(_ value: String) -> Date? {
    let text = value.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: text) { return date }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: text) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: text) { return date }
    }
    return nil
}

/// Split `--tags "a, b"` / `--add-tag "a, b"` style values into individual tags.
func splitTags(_ values: [String]) -> [String] {
    values
        .flatMap { $0.components(separatedBy: ",") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}
