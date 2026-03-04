import Foundation

/// Runs git sync (pull + push) in the vault directory
public func gitSync(vaultPath: String) throws {
    let expandedPath = (vaultPath as NSString).expandingTildeInPath

    // git pull --rebase
    try runGit(["pull", "--rebase"], in: expandedPath, label: "pull")

    // git add -A
    try runGit(["add", "-A"], in: expandedPath, label: "stage")

    // Check if there are staged changes
    let diffResult = try runGitCapture(["diff", "--cached", "--quiet"], in: expandedPath)
    if diffResult != 0 {
        // There are changes to commit
        try runGit(["commit", "-m", "sync: update notes"], in: expandedPath, label: "commit")
    }

    // git push
    try runGit(["push"], in: expandedPath, label: "push")
}

// MARK: - Helpers

@discardableResult
func runGit(_ args: [String], in directory: String, label: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    if process.terminationStatus != 0 {
        throw GitError.commandFailed(label: label, output: output)
    }

    return output
}

func runGitCapture(_ args: [String], in directory: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

public enum GitError: Error, CustomStringConvertible {
    case commandFailed(label: String, output: String)

    public var description: String {
        switch self {
        case let .commandFailed(label, output):
            "git \(label) failed: \(output)"
        }
    }
}
