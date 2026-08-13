import AppKit
import SwiftUI

/// Settings window. All preferences are gathered here — the menu bar's "…" menu holds actions only.
struct SettingsWindow: View {
    static let id = "settings"

    let store: SessionStore
    let preferences: AppPreferences
    let updates: UpdateCheck

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            SettingsPage(store: store, preferences: preferences, updates: updates)
        }
        .background(theme.bg)
        .frame(width: 560, height: 560)
        // The `Window(L("Settings"), …)` title is evaluated in the App's scene builder, which
        // the language scope can't reach — set it from inside the view so the title bar turns
        // over with the rest of the window instead of staying in the old language.
        .navigationTitle(L("Settings"))
    }
}

/// Split out into a separate page for the same reason as `MainWindowPage`: `ImageRenderer`
/// doesn't expand `ScrollView` — the content has to sit outside the ScrollView to render at all.
struct SettingsPage: View {
    let store: SessionStore
    let preferences: AppPreferences
    let updates: UpdateCheck

    @Environment(\.theme) private var theme
    @Environment(\.isOffscreenRender) private var isOffscreenRender

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rule

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
        // The login item can be switched off in System Settings while this window is
        // closed, so the switch is re-read on the way in rather than trusted.
        .onAppear { preferences.launchAtLogin.refresh() }
    }

    private var rule: some View {
        Rectangle().fill(theme.rule).frame(height: 1)
    }

    private var header: some View {
        Text(L("Settings"))
            .font(.system(size: 22, weight: .medium, design: .serif))
            .foregroundStyle(theme.text)
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 18)
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
        SettingRow(label: L("About"), note: L("Reads session records from ~/.claude — read-only, never written to.")) {
            VStack(alignment: .leading, spacing: 7) {
                Text(Self.appName)
                    .font(Theme.sessionTitle)
                    .foregroundStyle(theme.text)
                if case .available(let release) = updates.state {
                    UpdateNotice(release: release)
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

/// "There's a newer one", plus both ways of getting it.
///
/// Two paths because there are two ways in — the zip from Releases and the Homebrew cask — and
/// which one applies isn't something the app can tell: a cask-installed copy sits at exactly the
/// same `/Applications` path as one dragged there by hand. Offering both beats guessing wrong and
/// sending a `brew` user to a zip they'd have to unpack over their managed install.
///
/// The `brew` line prints the command itself rather than saying "copy the command": it's shorter
/// than the sentence describing it, and someone who'd rather type it into a terminal they already
/// have open can just read it.
private struct UpdateNotice: View {
    let release: UpdateCheck.Release

    @Environment(\.theme) private var theme
    @Environment(\.isOffscreenRender) private var isOffscreenRender
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // `dotWaiting` is the palette's "this one needs you" amber, already carried by the
            // session dots — same signal, so it should be the same colour.
            Text(L("\(release.version) is available"))
                .font(Theme.meta)
                .foregroundStyle(Theme.dotWaiting)

            HStack(spacing: 9) {
                tappable(
                    Text(L("Download"))
                        .font(Theme.meta)
                        .foregroundStyle(theme.muted)
                ) { NSWorkspace.shared.open(release.page) }

                Text("·")
                    .font(Theme.meta)
                    .foregroundStyle(theme.faint)

                tappable(
                    Text(copied ? L("Copied") : UpdateCheck.brewCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(copied ? Theme.dotRunning : theme.muted)
                ) { copyBrewCommand() }
            }
        }
    }

    /// `ImageRenderer` draws AppKit-backed controls as a yellow prohibition sign, so a render
    /// gets the label without the button wrapped around it — same text, same place.
    @ViewBuilder
    private func tappable(_ label: some View, action: @escaping () -> Void) -> some View {
        if isOffscreenRender {
            label
        } else {
            Button(action: action) { label }.buttonStyle(.plain)
        }
    }

    private func copyBrewCommand() {
        UpdateCheck.copyBrewCommand()
        copied = true
        // Reverts on its own: a permanent "Copied" would leave the command unreadable for anyone
        // who wanted to read it rather than paste it.
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
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

/// Right-aligned label on the left, control on the right — same skeleton as the main window's gutter, just narrower.
private struct SettingRow<Content: View>: View {
    let label: String
    var note: String?
    @ViewBuilder let content: Content

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            // 78, not 62: "Appearance" was the one label that didn't fit, and truncating
            // it to "Appeara…" made the settings page look broken.
            Text(label)
                .font(Theme.projectName)
                .foregroundStyle(theme.muted)
                .frame(width: 78, alignment: .trailing)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 8) {
                content
                if let note {
                    Text(note)
                        .font(Theme.meta)
                        .foregroundStyle(theme.faint)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }
}
