import ArgumentParser
import Foundation

/// Shared --json flag for all commands
struct OutputOption: ParsableArguments {
    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8)!)
}

func printJSONDict(_ dict: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
