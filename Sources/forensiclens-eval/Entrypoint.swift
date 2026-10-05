import Foundation

/// Process entry point for `forensiclens-eval`.
///
/// Uses `@main` rather than top-level code in a `main.swift` so that
/// `@testable import forensiclens_eval` doesn't fire off a real run (and
/// its `exit()` call) the moment the test binary loads -- see
/// `forensiclens-cli`'s `Entrypoint.swift` for the same pattern.
@main
struct Entrypoint {
    static func main() async {
        exit(await EvalCLI.run(arguments: CommandLine.arguments))
    }
}
