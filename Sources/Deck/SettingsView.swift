import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("theme") private var themeID = Accent.all[0].id
    @Environment(\.accent) private var accent
    @State private var confirmErase = false
    @AppStorage("clipboardHours") private var clipboardHours = 24
    @AppStorage("clipboardIgnore") private var clipboardIgnore = "1Password, Bitwarden, Keychain Access, Passwords"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader(title: "Settings", subtitle: "Everything stays on this Mac.")

                Tile {
                    TileLabel(text: "Color theme")
                    HStack(spacing: 8) {
                        ForEach(Accent.all) { a in
                            Button { themeID = a.id } label: {
                                VStack(spacing: 6) {
                                    HStack(spacing: 0) {
                                        a.surface; a.accent; a.soft
                                    }
                                    .frame(height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(themeID == a.id ? a.accent : C.border, lineWidth: themeID == a.id ? 1 : 0.5))
                                    Text(a.id).font(F.label).foregroundStyle(themeID == a.id ? C.text : C.text2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 100)

                SetupCard().frame(height: 130)

                Tile {
                    TileLabel(text: "Extra formats (optional)")
                    Text("Bigger helpers, only downloaded if you turn them on.").font(F.body).foregroundStyle(C.text2)
                    ForEach(Array(Setup.addOns.enumerated()), id: \.element.id) { i, a in
                        Row(divider: i < Setup.addOns.count - 1) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).font(F.body)
                                Text(a.detail).font(F.label).foregroundStyle(C.text2)
                            }
                            Spacer()
                            AddOnButton(addOn: a)
                        }
                    }
                }
                .frame(height: 170)

                Tile {
                    TileLabel(text: "Clipboard history")
                    Picker("Forget copied things after", selection: $clipboardHours) {
                        Text("1 hour").tag(1); Text("8 hours").tag(8); Text("1 day").tag(24); Text("1 week").tag(168)
                    }
                    .font(F.body)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Never remember copies from these apps").font(F.body)
                        TextField("App names, separated by commas", text: $clipboardIgnore).textFieldStyle(.roundedBorder).font(F.body)
                    }
                }
                .frame(height: 140)

                Tile {
                    TileLabel(text: "Privacy")
                    Text("Deck has no accounts, no tracking and no cloud. Private things (clipboard, journal, private notes) are encrypted on this Mac.")
                        .font(F.body).foregroundStyle(C.text2).fixedSize(horizontal: false, vertical: true)
                    Button("Erase all Deck data…") { confirmErase = true }.buttonStyle(.pill)
                }
                .frame(height: 130)
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
        .background(C.bg)
        .confirmationDialog("Erase all Deck data?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { erase() }
        } message: {
            Text("Your activity, focus history, habits, journal and clipboard history will be deleted. Notes in Documents and your calendar are kept.")
        }
    }

    private func erase() {
        let ctx = Store.context
        for model in [Activity.self, FocusSession.self] as [any PersistentModel.Type] + PlanModels.all + FocusModels.all + NotesModels.all + InboxModels.all {
            try? ctx.delete(model: model)
        }
        try? ctx.save()
        try? FileManager.default.removeItem(at: Vault.folder)
    }
}
