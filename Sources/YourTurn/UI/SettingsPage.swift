import AppKit
import SwiftUI

/// The settings tab of the main window. All preferences are gathered here — the menu bar's "…"
/// menu holds actions only.
///
/// This used to be a window of its own, 560pt wide with its own title and its own serif header.
/// It's a page now: an app that lives in the menu bar shouldn't need two windows, and the
/// settings had nothing in them that the main window's page couldn't hold. What that cost is one
/// number — the label column went from 78 to `Theme.gutter`, so these rows hang off the same
/// spine as the session list and the usage sections rather than a narrower one of their own.
struct SettingsPage: View {
    let store: SessionStore
    let preferences: AppPreferences
    let updates: UpdateCheck
    /// Owned by `Navigation`, not by this page: the menu bar panel's badge has to be able to open
    /// the window with the sheet already up.
    @Binding var showingUpdate: Bool

    @Environment(\.theme) private var theme
    @Environment(\.isOffscreenRender) private var isOffscreenRender

    /// Re-read on every appearance rather than stored — `~/.claude/settings.json` belongs to
    /// Claude Code, and a remembered `true` would go on claiming the bridge was installed after
    /// somebody edited it back out by hand.
    @State private var bridge = StatusLineBridge.State.off
    @State private var bridgeFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(label: L("Appearance"), note: appearanceNote) {
                PillPicker(
                    options: Appearance.allCases,
                    selection: Bindable(preferences).appearance
                ) { $0.displayName }
            }
            rule

            SettingRow(label: L("Language"), note: languageNote) {
                PillPicker(
                    options: AppLanguage.allCases,
                    selection: Bindable(preferences).language
                ) { $0.displayName }
            }
            rule

            SettingRow(label: L("Startup"), note: startupNote) {
                HStack(spacing: 12) {
                    if isOffscreenRender {
                        StaticValue(text: preferences.launchAtLogin.isEnabled ? L("On") : L("Off"))
                    } else {
                        Toggle("", isOn: Binding(
                            get: { preferences.launchAtLogin.isEnabled },
                            set: { preferences.launchAtLogin.set($0) }
                        ))
                        .labelsHidden()
                        // Nothing `register()` can do while the user has it switched off
                        // system-side; the button next to it is the only way back.
                        .disabled(preferences.launchAtLogin.needsApproval)
                        if preferences.launchAtLogin.needsApproval {
                            Button(L("Open Login Items")) { openLoginItemsSettings() }
                        }
                    }
                }
            }
            rule

            SettingRow(label: L("Terminal"), note: L("Which terminal opens a new window when resuming a closed session.")) {
                if isOffscreenRender {
                    StaticValue(text: preferences.terminal.displayName)
                } else {
                    Picker("", selection: Bindable(preferences).terminal) {
                        ForEach(preferences.installedTerminals) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
            rule

            SettingRow(label: L("Editor"), note: L("Used by the right-click menu's \"Open with…\".")) {
                if isOffscreenRender {
                    StaticValue(text: preferences.editor.displayName)
                } else {
                    Picker("", selection: Bindable(preferences).editor) {
                        ForEach(preferences.installedEditors) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
            rule

            SettingRow(label: L("Claude allowance"), note: allowanceNote) {
                HStack(spacing: 12) {
                    if isOffscreenRender {
                        StaticValue(text: bridgeIsOn ? L("On") : L("Off"))
                    } else {
                        // The setter is wrapped in a closure rather than passed as `set: setBridge`:
                        // the method reference makes swiftc 6.2.4 abort in IRGen while emitting the
                        // reabstraction thunk for it.
                        Toggle("", isOn: Binding(get: { bridgeIsOn }, set: { setBridge($0) }))
                            .labelsHidden()
                    }
                }
            }
            rule

            SettingRow(label: L("Archive"), note: L("Archiving is stored only in Your Turn's own data — never written back to ~/.claude.")) {
                HStack(spacing: 12) {
                    Text(archiveSummary)
                        .font(Theme.sessionTitle)
                        .foregroundStyle(theme.text)
                    if !isOffscreenRender {
                        Button(L("Clear")) { store.archive.clear() }
                            .disabled(store.archive.archived.isEmpty)
                    }
                }
            }
            rule

            SettingRow(label: L("Starred"), note: L("Starred projects are pinned to the top of the main window.")) {
                HStack(spacing: 12) {
                    Text(pinSummary)
                        .font(Theme.sessionTitle)
                        .foregroundStyle(theme.text)
                    if !isOffscreenRender {
                        Button(L("Clear all")) { store.pins.clear() }
                            .disabled(store.pins.pinned.isEmpty)
                    }
                }
            }
            rule

            about
        }
        // The login item can be switched off in System Settings while the app is elsewhere, so
        // the switch is re-read every time this tab comes up rather than trusted. `settings.json`
        // is somebody else's file for exactly the same reason, so it gets re-read here too.
        .onAppear {
            preferences.launchAtLogin.refresh()
            bridge = StatusLineBridge.state()
        }
    }

    private var bridgeIsOn: Bool { if case .on = bridge { return true } else { return false } }

    private func setBridge(_ enabled: Bool) {
        bridgeFailure = nil
        do {
            try enabled ? StatusLineBridge.enable() : StatusLineBridge.disable()
        } catch {
            bridgeFailure = error.localizedDescription
        }
        bridge = StatusLineBridge.state()
    }

    /// Says what the switch will do to somebody else's file *before* it does it, and what it did
    /// afterwards. The chained case gets its own sentence because "we edited your settings and
    /// your status line still works" is not something anyone should have to verify by hand.
    private var allowanceNote: String {
        if let bridgeFailure { return bridgeFailure }
        switch bridge {
        case .off:
            return L("Your 5-hour and weekly limits, read from Claude Code's status line — the only place it publishes them. Switching this on writes one key (statusLine) into ~/.claude/settings.json, and that is the only thing Your Turn ever writes there.")
        case .foreign:
            return L("You already have a status line. Switching this on keeps it: Your Turn's bridge runs first and hands it the same input untouched.")
        case .on(let chained):
            let where_ = chained == nil
                ? L("Claude Code's status line now shows what's left, and Your Turn reads it from there.")
                : L("Chained to the status line you already had, which still runs and still prints its own line.")
            return where_ + " " + L("The numbers arrive after Claude Code's next reply.")
        }
    }

    private var rule: some View {
        Rectangle().fill(theme.rule).frame(height: 1)
    }

    /// Each appearance gets one line describing what it actually looks like.
    /// "Follow System" specifically calls out which one it currently resolves to — otherwise,
    /// if the system is in dark mode, selecting it produces no visible change, making it look broken.
    private var appearanceNote: String {
        switch preferences.appearance {
        // Two whole sentences rather than interpolating a translated "dark"/"light" into
        // one: the fragment sits mid-sentence in Chinese, where the wording around it shifts too.
        case .system: preferences.systemIsDark
            ? L("Follows the system's light/dark setting. The system is currently dark.")
            : L("Follows the system's light/dark setting. The system is currently light.")
        // Lowercase "cream"/"warm black" describe the color; the picker's own labels are
        // Light / Dim / Dark, so capitalizing them here would read like a fourth palette.
        case .light: L("Cream-paper white — the brightest of the three.")
        case .dim: L("The same cream, dimmed to about 70% brightness. Easier on the eyes over a long session, still dark text on a light background.")
        case .dark: L("Warm black — the night end of the same paper.")
        }
    }

    /// Same shape as `appearanceNote`: "Follow System" has to name what it resolves to, or on an
    /// English system it looks like the setting did nothing.
    private var languageNote: String {
        guard preferences.language == .system else {
            return L("Overrides your macOS language. The whole app switches over immediately.")
        }
        return Localization.resolved == .traditionalChinese
            ? L("Follows your macOS language. It currently resolves to 繁體中文.")
            : L("Follows your macOS language. It currently resolves to English.")
    }

    /// Says what the switch does, unless macOS has something to say first.
    private var startupNote: String {
        if let failure = preferences.launchAtLogin.failure { return failure }
        if preferences.launchAtLogin.needsApproval {
            return L("macOS has this blocked. Allow \"Your Turn\" under Login Items to switch it back on.")
        }
        return L("Opens on its own once you log in. It has no Dock icon, so it just appears in the menu bar.")
    }

    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private var archiveSummary: String {
        let count = store.archive.archived.count
        // Two keys instead of splicing an "s" in: languages that don't pluralise (zh-Hant)
        // map both to the same sentence, and no stringsdict is needed for two languages.
        if count == 0 { return L("No sessions archived") }
        return count == 1 ? L("\(count) session archived") : L("\(count) sessions archived")
    }

    private var pinSummary: String {
        let count = store.pins.pinned.count
        if count == 0 { return L("No projects starred") }
        return count == 1 ? L("\(count) project starred") : L("\(count) projects starred")
    }

    private var about: some View {
        SettingRow(label: L("About"), note: L("Reads session records from ~/.claude — read-only, apart from the status-line bridge you switch on yourself.")) {
            VStack(alignment: .leading, spacing: 7) {
                Text(Self.appName)
                    .font(Theme.sessionTitle)
                    .foregroundStyle(theme.text)
                if case .available(let release) = updates.state {
                    UpdateBadge(version: release.version, compact: false) { showingUpdate = true }
                }
            }
        }
    }

    /// The .app's `CFBundleShortVersionString`, which `bundle.sh` and `release.sh` both stamp in.
    /// A bare `swift build` binary has no Info.plist at all — that's how `--render` runs — so the
    /// name stands alone rather than printing a made-up number next to it. Not localized: it's a
    /// product name plus a version string.
    private static var appName: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Your Turn \($0)" } ?? "Your Turn"
    }
}

/// Stands in for a native `Picker` while offscreen-rendering — same box, same value,
/// minus the control `ImageRenderer` can't draw.
private struct StaticValue: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(Theme.meta)
            .foregroundStyle(theme.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(width: 190, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.rule, lineWidth: 1))
    }
}

/// Right-aligned label in the gutter, control on the right — the same spine as the session rows
/// and `StatsRow`, which is the point of folding this page into the window: all three tabs hang
/// their content off one vertical line instead of each having its own.
///
/// The note is capped at 420pt rather than running to the window's edge. These are sentences, and
/// a sentence set 700pt wide at 11pt is measurably harder to track back to the next line — the
/// old 560pt window happened to enforce that, and widening the page removed the constraint
/// without removing the reason for it.
private struct SettingRow<Content: View>: View {
    let label: String
    var note: String?
    @ViewBuilder let content: Content

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(Theme.projectName)
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .frame(width: Theme.gutter, alignment: .trailing)
                .padding(.trailing, 22)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 8) {
                content
                if let note {
                    Text(note)
                        .font(Theme.meta)
                        .foregroundStyle(theme.faint)
                        .lineSpacing(2)
                        .frame(maxWidth: 420, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, Theme.pageInset)
        }
        .padding(.vertical, 18)
    }
}
