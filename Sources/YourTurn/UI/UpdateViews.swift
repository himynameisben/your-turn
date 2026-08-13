import AppKit
import SwiftUI

/// The "there's a newer one" chip.
///
/// Lives next to the menu bar panel's "All" and in the main window's masthead, because the first
/// version of this hid both routes inside a submenu off the "…" button — technically present,
/// practically invisible. It only exists when there's a release to point at, so the quiet state
/// is still no UI at all.
///
/// Wears the palette's `waitingChip` amber, the strongest "look here" it has. That's the same
/// colour as the session chips, and it can't be confused with one: those are a bare number, this
/// one has the word on it.
struct UpdateBadge: View {
    let version: String
    /// Bare "Update" where it has to share a line with other controls — the masthead and the
    /// panel footer. The settings About row is the one place with room, and the one place whose
    /// whole job is telling you which version is which, so there it names the version.
    var compact = true
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isOffscreenRender) private var isOffscreenRender
    @State private var isHovering = false

    var body: some View {
        if isOffscreenRender {
            label
        } else {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .help(L("\(version) is available"))
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 9))
            Text(compact ? L("Update") : L("Update to \(version)"))
                .font(Theme.chip)
        }
        .foregroundStyle(theme.waitingChip.fg)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.waitingChip.bg, in: .capsule)
        .opacity(isHovering ? 0.82 : 1)
        .contentShape(.capsule)
    }
}

/// What the badge opens: the version, and both ways of getting it.
///
/// Both routes are spelled out rather than detected — a cask-installed copy sits at exactly the
/// same `/Applications` path as one dragged there by hand, so the app cannot tell which way it
/// got there, and sending a `brew` user to a zip they'd unpack over their managed install is
/// worse than asking. Printing the command rather than describing it is deliberate too: "copy the
/// brew command" is longer than the command, and someone with a terminal already open can read it.
///
/// One sheet serves all three entry points (menu bar panel, masthead, settings), so there's a
/// single place that explains the choice.
struct UpdateSheet: View {
    let release: UpdateCheck.Release
    var dismiss: () -> Void = {}

    @Environment(\.theme) private var theme
    @Environment(\.isOffscreenRender) private var isOffscreenRender
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Not localized: a product name and a version number, same as the settings About row.
            Text("Your Turn \(release.version)")
                .font(.system(size: 19, weight: .medium, design: .serif))
                .foregroundStyle(theme.text)
            Text(L("You're running \(UpdateCheck.currentVersion ?? "—")."))
                .font(Theme.meta)
                .foregroundStyle(theme.faint)
                .padding(.top, 5)

            rule.padding(.vertical, 20)

            tappable(
                Text(L("Download from GitHub…"))
                    .font(Theme.sessionTitle)
                    .foregroundStyle(theme.inverted.fg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(theme.inverted.bg, in: .rect(cornerRadius: 8))
            ) { NSWorkspace.shared.open(release.page) }

            Text(L("Or, if you installed it with Homebrew:"))
                .font(Theme.meta)
                .foregroundStyle(theme.muted)
                .padding(.top, 22)
                .padding(.bottom, 7)

            tappable(
                HStack(spacing: 8) {
                    Text(copied ? L("Copied") : UpdateCheck.brewCommand)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(copied ? Theme.dotRunning : theme.text)
                    Spacer(minLength: 6)
                    // Without this the box reads as a code sample, and nobody clicks a code
                    // sample. It's the only thing marking the box as a control.
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? Theme.dotRunning : theme.faint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.rule, lineWidth: 1))
                .contentShape(.rect)
            ) { copyBrewCommand() }

            rule.padding(.vertical, 18)

            HStack {
                Spacer()
                if isOffscreenRender {
                    Text(L("Close")).font(Theme.meta).foregroundStyle(theme.muted)
                } else {
                    Button(L("Close"), action: dismiss)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(26)
        .frame(width: 400)
        .background(theme.bg)
    }

    private var rule: some View {
        Rectangle().fill(theme.rule).frame(height: 1)
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

extension View {
    /// Attached wherever the badge can be pressed. Takes the state rather than a release so the
    /// caller doesn't have to unwrap the enum before it knows whether to show anything.
    func updateSheet(_ state: UpdateCheck.State, isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            if case .available(let release) = state {
                UpdateSheet(release: release) { isPresented.wrappedValue = false }
            }
        }
    }
}
