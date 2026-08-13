import Foundation

/// Rolls a session's working directory up to the repository it belongs to.
///
/// Two separate problems, one fix. Measured across this machine's transcripts:
///
/// - **126 distinct `cwd` values for 36 actual projects.** `/fanproof`, `/fanproof/backend`
///   and `/fanproof/apps/liff` are one thing you work on, and splitting them across three
///   bars in a ranking makes every project look cheaper than it is.
/// - **Folder names collide.** 19 basenames covered more than one directory — three unrelated
///   projects each have a `backend`, three have a `liff`. Keying a cost breakdown on the
///   folder name silently merges other people's spend into yours.
///
/// So the key is the repository path and the label is its folder name. A directory outside
/// any repository — or one that's since been deleted, measured at 10 of 126 — keeps its own
/// path, which is the honest answer rather than a guess.
///
/// Deliberately **not** applied to the session pipeline: `SessionResolver` groups by exact
/// `cwd` because that's what drives the jump target, and rolling it up there would open the
/// wrong VS Code workspace.
enum ProjectRoot {
    /// The cache matters: 36,000 records share 126 directories, and each miss costs a walk up
    /// the tree with a `.git` stat at every level.
    static func resolve(_ path: String, cache: inout [String: String]) -> String {
        if let known = cache[path] { return known }
        let resolved = walkUp(path)
        cache[path] = resolved
        return resolved
    }

    static func name(of path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private static func walkUp(_ path: String) -> String {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: path).standardizedFileURL
        // Stops at the home directory: everything above it is shared with the rest of the
        // system, and a `.git` up there would swallow every project at once.
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        while current.path.count > home.count, current.path != "/" {
            if fm.fileExists(atPath: current.appending(path: ".git").path) { return current.path }
            current.deleteLastPathComponent()
        }
        return path
    }
}
