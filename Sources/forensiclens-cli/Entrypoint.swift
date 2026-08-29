import Foundation

/// Process entry point.
///
/// This lives in its own file, as an `@main` type, rather than as
/// top-level statements in a file named `main.swift`. A `main.swift`'s
/// top-level code runs the instant the module is loaded -- including by
/// `@testable import forensiclens_cli` from the test target, which would
/// fire off a real CLI invocation (and its `exit()` call) the moment the
/// test binary starts, before a single test runs. Moving the actual
/// invocation into `Entrypoint.main()` means the module only does
/// something when the real executable's synthesized entry point calls it.
@main
struct Entrypoint {
    static func main() async {
        exit(await CLI.run(arguments: CommandLine.arguments))
    }
}
