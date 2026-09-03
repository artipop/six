#if os(macOS)
import SwiftUI

/// The profile switcher: a dropdown, not a row of dots.
///
/// A row of coloured circles is fine for two profiles and unreadable for five, and everything you
/// might want to *do* to one of them was hidden in a right-click. This says which profile you are in,
/// in words, and opens onto the list — where the one you are in unfolds into its name, its colour and
/// the button that deletes it. Renaming and recolouring happen in place; there is no sheet, because a
/// modal window for a text field and eight swatches is a ceremony.
struct ProfileMenuButton: View {
    @Environment(BrowserState.self) private var browser
    @State private var showing = false

    var body: some View {
        let profile = browser.selectedProfile
        Button { showing = true } label: {
            HStack(spacing: 5) {
                ProfileDot(profile: profile, size: 15)
                Text(profile.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 3)
            .padding(.trailing, 6)
            .frame(height: 24)
            .background(.quaternary.opacity(showing ? 0.8 : 0.35),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(profile.isPrivate
              ? "Private browsing — nothing is kept; close it to forget the session"
              : "Profiles")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ProfilePopover().environment(browser)
        }
    }
}

/// The circle that stands for a profile everywhere: its colour, with its initial in it.
struct ProfileDot: View {
    let profile: Profile
    var size: CGFloat = 16

    var body: some View {
        Circle()
            .fill(profile.color)
            .frame(width: size, height: size)
            .overlay {
                if profile.isPrivate {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.55, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }
}

private struct ProfilePopover: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss
    /// Which row is unfolded. At most one — the editor is the row's back side, not a second list.
    @State private var editing: Profile.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(browser.profiles) { profile in
                ProfileRow(profile: profile, editing: $editing, dismiss: { dismiss() })
            }
            Divider().padding(.vertical, 5)
            footerButton("New Profile", systemImage: "plus") {
                // Created and opened for editing in one step: a profile arrives wanting a name, and
                // the place to give it one is where you already are.
                let name = String(localized: "New Profile")
                browser.addProfile(name: name, colorHex: Self.palette[browser.profiles.count % Self.palette.count])
                editing = browser.selectedProfileID
            }
            if browser.privateProfile == nil {
                footerButton("Private Window", systemImage: "eyeglasses") {
                    browser.newPrivateWindow()
                    dismiss()
                }
            }
        }
        .padding(8)
        .frame(width: 268)
    }

    static let palette = ["#5B8DEF", "#E8743B", "#38A169", "#9F7AEA",
                          "#E05252", "#D69E2E", "#2C9C9C", "#D45B9A"]

    private func footerButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One profile in the list, and — when it is unfolded — everything there is to say about it.
private struct ProfileRow: View {
    let profile: Profile
    @Binding var editing: Profile.ID?
    let dismiss: () -> Void

    @Environment(BrowserState.self) private var browser
    @State private var hovering = false
    @State private var name = ""

    private var isSelected: Bool { profile.id == browser.selectedProfileID }
    private var isEditing: Bool { editing == profile.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isEditing { editor }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var rowBackground: AnyShapeStyle {
        if isEditing { return AnyShapeStyle(.quaternary.opacity(0.7)) }
        if hovering { return AnyShapeStyle(.quaternary.opacity(0.45)) }
        return AnyShapeStyle(.clear)
    }

    /// The row itself. Unfolded, the name becomes the field you edit it in — the same line, so a
    /// rename never shows the old name above the new one.
    private var header: some View {
        HStack(spacing: 7) {
            ProfileDot(profile: profile, size: 17)
            if isEditing, !profile.isPrivate {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onAppear { name = profile.name }
                    .onSubmit { commitName() }
                    // Not on every keystroke: the name is the profile's folder on disk, and renaming
                    // it moves the bookmarks and the scratchpad with it. It waits for ⏎ or for the
                    // row to fold back up.
                    .onDisappear { commitName() }
            } else {
                Text(profile.name)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            Button { editing = isEditing ? nil : profile.id } label: {
                Image(systemName: isEditing ? "chevron.up" : "slider.horizontal.3")
                    .font(.system(size: 10))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || isEditing || isSelected ? 1 : 0)
            .help(isEditing ? "Done" : "Edit this profile")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else { return } // a click in the field is a click in the field
            browser.selectProfile(profile.id)
            dismiss()
        }
    }

    // MARK: The back side of a row

    @ViewBuilder
    private var editor: some View {
        if profile.isPrivate {
            // A private profile has no name and no colour worth keeping — the only thing to do with
            // it is end it, and with it everything it saw.
            Text("Nothing is kept in this profile. Closing it forgets the session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            deleteButton(title: "Close Private Browsing", enabled: true) { browser.closePrivateBrowsing() }
        } else {
            swatches
            deleteButton(title: "Delete Profile", enabled: browser.profiles.count > 1) {
                browser.removeProfile(profile.id)
            }
        }
    }

    /// Eight colours and the well that opens the system's own.
    ///
    /// The row is laid out by division rather than by counting points: the well is asked how wide it
    /// is and given exactly that, and what is left is split evenly between the swatches. It used to be
    /// eight 16 pt circles, a 6 pt gap between each and a 22 pt frame around the well — a sum that
    /// fitted the popover only as long as every number in it stayed true, and one of them was never
    /// true: `ColorPicker` is an `NSColorWell` and its own width is nearly twice the frame that was
    /// put around it. A frame does not clip, so the well simply stood past the edge of the popover.
    private var swatches: some View {
        HStack(spacing: 0) {
            ForEach(ProfilePopover.palette, id: \.self) { hex in
                let chosen = hex.caseInsensitiveCompare(profile.colorHex) == .orderedSame
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 16, height: 16)
                    .overlay {
                        Circle().strokeBorder(.primary.opacity(chosen ? 0.9 : 0), lineWidth: 2)
                    }
                    .contentShape(Circle())
                    .onTapGesture { browser.setProfileColor(profile.id, hex: hex) }
                    .frame(maxWidth: .infinity)
            }
            ColorPicker("", selection: Binding(
                get: { profile.color },
                set: { browser.setProfileColor(profile.id, hex: $0.hexString) }
            ), supportsOpacity: false)
            .labelsHidden()
            .fixedSize()
            .layoutPriority(1) // it gets the width it needs; the swatches share what is left
            .help("Any other colour")
        }
        .frame(maxWidth: .infinity)
    }

    private func deleteButton(title: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .help(enabled ? "" : String(localized: "The last profile stays"))
    }

    private func commitName() {
        browser.renameProfile(profile.id, to: name)
    }
}

extension Color {
    var hexString: String {
        let resolved = resolve(in: EnvironmentValues())
        let r = Int((resolved.red * 255).rounded()), g = Int((resolved.green * 255).rounded()), b = Int((resolved.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
#endif
