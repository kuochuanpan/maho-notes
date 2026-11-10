import ArgumentParser
import Foundation

/// Shared --json flag for all commands
struct OutputOption: ParsableArguments {
    @Flag(name: .long, help: "Output in JSON format (errors too: {\"error\": {\"code\", \"message\", …}})")
    var json: Bool = false

    func validate() throws {
        // Recorded while parsing, so an error thrown later is reported in the same format.
        if json { CLIRuntime.jsonOutput = true }
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8)!)
}

func printJSONDict(_ dict: [String: Any]) throws {
    let data = try JSONSerialization.data(
        withJSONObject: dict,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    print(String(data: data, encoding: .utf8)!)
}
