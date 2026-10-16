import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("theme") private var themeID = Accent.all[0].id
    @Environment(\.accent) private var accent
    @State private var confirmErase = false
    @State private var launchAtLogin = LoginItem.isOn
    @AppStorage(UserName.key) private var name = UserName.fallback
    @AppStorage("clock24") private var clock24 = true
    @AppStorage("clipboardHours") private var clipboardHours = 24
    @AppStorage("clipboardIgnore") private var clipboardIgnore = "1Password, Bitwarden, Keychain Access, Passwords"
    @AppStorage("clipboardOn") private var clipboardOn = true

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

                Tile {
                    HStack {
                        Text("What should Deck call you?").font(F.body)
                        Spacer()
                        TextField("Your name", text: $name).deckField().frame(width: 180)
                    }
                    Toggle(isOn: $clock24) { Text("24-hour clock").font(F.body) }.toggleStyle(.switch)
                }
                .fixedSize(horizontal: false, vertical: true)

                Tile {
                    Toggle(isOn: $launchAtLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start Deck when you log in").font(F.body)
                            Text("It waits quietly in the menu bar.").font(F.label).foregroundStyle(C.text2)
                        }
                    }
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
                }
                .frame(height: 70)

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

                UpdateSettings()
                WeatherSettings()
                Tile {
                    TileLabel(text: "Menu bar panel")
                    Text("Pick what shows when you click Deck in the menu bar.").font(F.body).foregroundStyle(C.text2)
                    PanelTileSwitches(key: PanelTile.menuBarKey, tiles: PanelTile.menuBar)
                }
                .fixedSize(horizontal: false, vertical: true)

                PanelSettingsSection()
                NotesSettingsSection()

                Tile {
                    TileLabel(text: "Clipboard history")
                    Toggle("Remember what I copy", isOn: $clipboardOn)
                        .toggleStyle(.switch).font(F.body)
                        .onChange(of: clipboardOn) { Clipboard.shared.applySetting() }
                    Text("Forget copied things after").font(F.body)
                    PillPicker(selection: $clipboardHours, options: [("1 hour", 1), ("8 hours", 8), ("1 day", 24), ("1 week", 168)])
                        .disabled(!clipboardOn)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Never remember copies from these apps").font(F.body)
                        TextField("App names, separated by commas", text: $clipboardIgnore).deckField()
                    }
                    .disabled(!clipboardOn)
                    Text("Things that look like passwords are never remembered.").font(F.label).foregroundStyle(C.text2)
                }
                .fixedSize(horizontal: false, vertical: true)

                Tile {
                    TileLabel(text: "Privacy")
                    Text("Deck has no accounts, no tracking and no cloud. The only automatic internet use is the weather (only if you turn it on) and checking GitHub for Deck updates (you can turn that off). Private things (clipboard, journal, private notes) are encrypted on this Mac.")
                        .font(F.body).foregroundStyle(C.text2).fixedSize(horizontal: false, vertical: true)
                    Text("Notes are kept in Documents › Deck Notes. If iCloud syncs your Documents folder, your notes sync too; private notes stay encrypted.")
                        .font(F.body).foregroundStyle(C.text2).fixedSize(horizontal: false, vertical: true)
                    Button("Erase all Deck data…") { confirmErase = true }.buttonStyle(.pill)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
        .background(C.bg)
        .confirmationDialog("Erase all Deck data?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { erase() }
        } message: {
            Text("Your activity, focus history, habits, journal and clipboard history will be deleted. Notes in Documents, downloads and your calendar are kept.")
        }
    }

    private func erase() {
        let ctx = Store.context
        for model in [Activity.self, FocusSession.self] as [any PersistentModel.Type] + PlanModels.all + FocusModels.all + NotesModels.all + InboxModels.all {
            try? ctx.delete(model: model)
        }
        try? ctx.save()
        Clipboard.shared.clear()
        // Private notes are kept, so their key is too; without any, the key goes and a new one is made next time.
        if !NoteFiles.list().contains(where: \.isPrivate) { Vault.deleteKey() }
        // Deck.store and downloads.session stay: the database is open and downloads may be running.
    }
}
