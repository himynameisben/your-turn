import Observation
import ServiceManagement

/// "Open at login", backed by `SMAppService.mainApp`.
///
/// Keeps **no** copy in UserDefaults. The login item lives in the system's own
/// database, and the user can switch it off in System Settings → General → Login
/// Items without telling the app — a remembered `true` would then contradict what
/// macOS is actually doing. Every read goes back to `status`.
@Observable
@MainActor
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status

    /// Set when the system refuses a change. Snapping the switch back with no
    /// explanation reads as a bug, so whatever macOS said gets shown under the row.
    private(set) var failure: String?

    var isEnabled: Bool { status == .enabled }

    /// The user turned it off in System Settings. `register()` cannot override that
    /// decision — only they can switch it back on — so the row offers the shortcut
    /// there instead of a toggle that would silently do nothing.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// Registers whichever bundle the running binary sits in: toggling this from a
    /// copy launched out of `build/` installs a login item pointing at `build/`,
    /// which stops working the next time `bundle.sh` wipes that directory. Toggle it
    /// from the copy in /Applications.
    func set(_ enabled: Bool) {
        failure = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }

    /// `--login-item [on|off]` — the verification entry point for this setting.
    ///
    /// There's no other way to check it: `SMAppService` registrations don't appear in
    /// the old `System Events` login-item list that AppleScript can read, and the
    /// system's Background Task Management database needs root. The only process that
    /// can answer for this bundle is this bundle, so it has to answer on its own.
    /// Run the binary **inside** the .app — a bare `swift build` binary has no bundle
    /// to register and always reports notFound.
    static func cli(_ argument: String?) {
        let service = LaunchAtLogin()
        switch argument {
        case "on": service.set(true)
        case "off": service.set(false)
        case nil: break
        default:
            print("usage: YourTurn --login-item [on|off]")
            return
        }
        if let failure = service.failure { print("error: \(failure)") }
        print("login item: \(service.status.label)")
    }
}

private extension SMAppService.Status {
    var label: String {
        switch self {
        case .enabled: "enabled"
        case .notRegistered: "not registered"
        case .requiresApproval: "requires approval (user disabled it in System Settings)"
        // Measured: mainApp answers notFound until it has been registered once, and
        // notRegistered after an unregister — so notFound isn't only "there's no bundle".
        case .notFound: "not found (never registered, or not inside an app bundle)"
        @unknown default: "unknown (\(rawValue))"
        }
    }
}
