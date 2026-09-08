import Foundation

// `revis-updater`, bundled at Contents/Helpers and never installed anywhere else. It has
// exactly one job and one subcommand; the subcommand is spelled out rather than assumed so
// that a stray execution — a curious user, a Launch Services probe — does nothing at all.
let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "apply-update":
    ApplyUpdate.run(Array(arguments.dropFirst()))
default:
    FileHandle.standardError.write(Data("""
        revis-updater — the helper Revis uses to replace itself during an update.

        Usage: revis-updater apply-update --pid <pid> --staged <path> --installed <path>

        Not meant to be run by hand.

        """.utf8))
    exit(2)
}
