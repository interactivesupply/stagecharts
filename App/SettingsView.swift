import SwiftUI
import UniformTypeIdentifiers
import StageMIDI
import ChordProKit

/// App settings: MIDI connection, action mapping with MIDI learn, song numbers, monitor, display.
@available(iOS 18, macOS 14, *)
struct SettingsView: View {
    @EnvironmentObject var midi: MIDIController
    @EnvironmentObject var library: SongLibrary
    @EnvironmentObject var band: BandSync
    @EnvironmentObject var googleAuth: GoogleAuth
    @EnvironmentObject var drive: GoogleDriveSync
    @EnvironmentObject var importer: AutoImporter
    @AppStorage("autoImportDownloads") private var autoImport = false
    @AppStorage("songSelectInBrowser") private var songSelectInBrowser = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chartStyle") private var styleRaw = ChartStyle.classic.rawValue
    @AppStorage("chartColumns") private var columnsRaw = ChartColumns.auto.rawValue
    @AppStorage(PageTurn.storageKey) private var pageTurnRaw = PageTurn.scroll.rawValue
    var showsDoneButton = true
    @State private var pickingFolder = false
    @State private var pickingSong = false
    @State private var songSearch = ""
    @State private var pendingSongRow: String?
    @State private var folderError: String?

    @State private var showCCLIReport = false
    @AppStorage("chordTapHelp") private var chordTapHelp = true

    // MARK: Categories

    enum Category: String, CaseIterable, Identifiable, Hashable {
        case display, band, library, songs, helix, connections, control, tempo, monitor, map
        var id: String { rawValue }
        var title: String {
            switch self {
            case .display: return "Display"
            case .band: return "Band"
            case .library: return "Library & sync"
            case .songs: return "SongSelect & AI"
            case .helix: return "Helix"
            case .connections: return "MIDI connections"
            case .control: return "MIDI control"
            case .tempo: return "Tempo sync"
            case .monitor: return "MIDI monitor"
            case .map: return "MIDI map"
            }
        }
        var icon: String {
            switch self {
            case .display: return "textformat.size"
            case .band: return "person.3.fill"
            case .library: return "externaldrive.fill.badge.icloud"
            case .songs: return "music.note.list"
            case .helix: return "guitars"
            case .connections: return "cable.connector"
            case .control: return "pianokeys"
            case .tempo: return "metronome.fill"
            case .monitor: return "waveform.path.ecg"
            case .map: return "tablecells"
            }
        }
        var color: Color {
            switch self {
            case .display: return .gray
            case .band: return .green
            case .library: return .blue
            case .songs: return .purple
            case .helix: return .indigo
            case .connections: return .orange
            case .control: return .pink
            case .tempo: return .red
            case .monitor: return .teal
            case .map: return .cyan
            }
        }
        /// Extra words the search matches.
        var keywords: String {
            switch self {
            case .display: return "chart style columns theme text chord diagram guitar piano fingering tap page turn up down pedal scroll"
            case .band: return "follow lead leader followers ipads scrolling"
            case .library: return "google drive sync folder icloud dropbox ccli report usage"
            case .songs: return "songselect import upgrade downloads ai convert claude photo scan api key"
            case .helix: return "line 6 helix native guitar preset patch tone amp snapshot hlx ai"
            case .connections: return "network session inputs usb bluetooth routes thru pass channel ableton audio midi setup"
            case .control: return "channel actions learn next previous page scroll song numbers program change set slots two-way send"
            case .tempo: return "midi clock send receive pass through ableton link bpm start stop"
            case .monitor: return "log messages debug routing map activity routes sent received"
            case .map: return "rig reference document mappings ableton playback mc8 morningstar channels cc chart"
            }
        }
        var section: String {
            switch self {
            case .display, .band, .library, .songs, .helix: return "StageCharts"
            case .connections, .control, .tempo, .monitor, .map: return "MIDI"
            }
        }
    }

    @State private var category: Category? = {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments       // testing: -settingsCategory map
        if let i = a.firstIndex(of: "-settingsCategory"), i + 1 < a.count { return Category(rawValue: a[i + 1]) }
        #endif
        return nil
    }()
    @State private var search = ""
    private var visibleCategories: [Category] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Category.allCases }
        return Category.allCases.filter { ($0.title + " " + $0.keywords).lowercased().contains(q) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $category) {
                ForEach(["StageCharts", "MIDI"], id: \.self) { group in
                    let items = visibleCategories.filter { $0.section == group }
                    if !items.isEmpty {
                        Section(group) {
                            ForEach(items) { c in
                                NavigationLink(value: c) { CategoryLabel(category: c) }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("StageCharts \(BandSync.appVersion)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search settings")
            .navigationTitle("Settings")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            #endif
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { midi.learning = nil; dismiss() }
                    }
                }
            }
        } detail: {
            NavigationStack {
                if let category {
                    detail(category)
                } else {
                    Text("Choose a category").foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            guard category == nil else { return }
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-settingsCategory"),       // testing
               i + 1 < ProcessInfo.processInfo.arguments.count,
               let c = Category(rawValue: ProcessInfo.processInfo.arguments[i + 1]) { category = c; return }
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom != .phone { category = .display }
            #else
            category = .display
            #endif
        }
        .onChange(of: search) { _, _ in
            if let first = visibleCategories.first, !visibleCategories.contains(where: { $0 == category }) { category = first }
        }
        .sheet(isPresented: $showCCLIReport) {
            if #available(iOS 16.0, *) { CCLIReportView() }
        }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 620)
        #endif
        .onDisappear { midi.learning = nil }
    }

    @ViewBuilder private func detail(_ c: Category) -> some View {
        Form {
            if let notice = midi.learnNotice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            switch c {
            case .display:
                Section("Charts") {
                    Picker("Chart style", selection: $styleRaw) {
                        ForEach(ChartStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Columns", selection: $columnsRaw) {
                        ForEach(ChartColumns.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Section {
                    Picker("Page up / down", selection: $pageTurnRaw) {
                        ForEach(PageTurn.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } footer: {
                    Text("For a foot pedal, MIDI or the keyboard's Page Up/Down. A whole page moves a full screen and keeps the last line at the top so you don't lose your place.")
                }
                Section {
                    Toggle("Tap a chord to see how to play it", isOn: $chordTapHelp)
                } footer: {
                    Text("Shows a guitar chord box (with other shapes up the neck) or a piano keyboard. Turn off if you tap the chart to hide the toolbar during a set.")
                }
            case .band:
                bandSection
            case .library:
                GoogleDriveSection()
                // The folder option is for iCloud Drive / Dropbox users; hidden while Google sync is on.
                if !googleAuth.isSignedIn { librarySection }
                Section {
                    Button("CCLI usage report…") { showCCLIReport = true }
                } header: {
                    Text("Reports")
                } footer: {
                    Text("Songs used in your set lists over a period, with CCLI numbers, ready for your CCLI copy report.")
                }
            case .songs:
                songSelectSection
                AISettingsSection()
            case .helix:
                HelixSettingsSection()
            case .connections:
                connectionSection
                MIDIRoutesSection(midi: midi)
            case .control:
                listenSection
                actionsSection
                setSlotsSection
                songsSection
                sendSection
            case .tempo:
                clockSection
                LinkSettingsSection(link: midi.link)
            case .monitor:
                MIDIRoutingMonitor(midi: midi)
                monitorSection
            case .map:
                MIDIMapPage(midi: midi)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(c.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Sections

    private var songSelectSection: some View {
        Section {
            Button("Open SongSelect…") { afterClosingSettings { importer.browserURL = SongSelect.home } }
            Button("Upgrade queue: \(importer.upgradeCandidates.count) songs need a transposable chart") {
                afterClosingSettings { importer.startQueue() }
            }
                .disabled(importer.upgradeCandidates.isEmpty)
            #if os(macOS)
            Toggle("Import SongSelect downloads automatically", isOn: Binding(get: { autoImport }, set: { autoImport = $0; importer.setWatching($0) }))
            if autoImport {
                LabeledContent("Watching", value: importer.watchFolder.path)
                Button("Choose downloads folder…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    p.directoryURL = importer.watchFolder
                    if p.runModal() == .OK, let u = p.url { importer.setWatchFolder(u) }
                }
                Toggle("Open SongSelect pages in my web browser (e.g. Chrome)", isOn: $songSelectInBrowser)
            }
            #endif
        } header: {
            Text("SongSelect")
        } footer: {
            Text("Download a chord sheet (PDF or ChordPro) and StageCharts imports it: songs you already have are upgraded in place (set lists, keys, capos, notes and MIDI kept), new ones are added. On the Mac it can also watch your downloads folder for files saved from your web browser.")
        }
    }

    /// On iPad, Settings is a sheet: the SongSelect browser (presented by the main screen) can only
    /// appear once Settings is closed. On the Mac, Settings is its own window, so open straight away.
    private func afterClosingSettings(_ action: @escaping () -> Void) {
        #if os(iOS)
        midi.learning = nil
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: action)
        #else
        action()
        #endif
    }

    private var librarySection: some View {
        Section {
            LabeledContent("Location", value: library.locationName)
            Button(library.usesCustomFolder ? "Choose a different folder…" : "Use a shared folder (iCloud Drive, Dropbox…)…") {
                pickingFolder = true
            }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do { try library.useFolder(url); folderError = nil }
                    catch { folderError = "Couldn't use that folder: \(error.localizedDescription)" }
                case .failure(let error):
                    folderError = error.localizedDescription
                }
            }
            if library.usesCustomFolder {
                Button("Refresh from folder") { library.reloadAll() }
                Button("Use this device's storage instead") { library.useDeviceStorage() }
            }
            if let folderError { Text(folderError).foregroundStyle(.red) }
        } header: {
            Text("Library folder (advanced)")
        } footer: {
            Text("Keep the library in a folder synced by another service, such as iCloud Drive or Dropbox. For Google Drive, use “Sign in with Google” above instead.")
        }
    }

    private var bandSection: some View {
        Section {
            Picker("This device", selection: $band.role) {
                ForEach(BandSync.Role.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Status", value: band.statusText)
            if band.role == .follow {
                Toggle("Follow the leader's scrolling", isOn: $band.followsScrolling)
            }
            if band.role == .lead && !band.peers.isEmpty {
                ForEach(band.peers, id: \.self) { Label($0 + band.versionNote(for: $0), systemImage: "ipad") }
            }
        } header: {
            Text("Band follow mode")
        } footer: {
            Text("Lead on your iPad and Follow on the band's iPads (same Wi-Fi, or nearby). Followers receive the set list and charts, then follow your song changes and scrolling. Each person keeps their own text size, columns and theme.")
        }
    }

    private var connectionSection: some View {
        Section {
            LabeledContent("Status", value: midi.status)
            LabeledContent("Network session", value: midi.networkSessionName)
            DisclosureGroup("Inputs (\(midi.sourceNames.count))") {
                ForEach(midi.sourceNames, id: \.self) { Text($0) }
                Button("Rescan") { midi.connectSources() }
            }
            BluetoothMIDIButton { midi.connectSources() }
        } header: {
            Text("MIDI connection")
        } footer: {
            #if os(iOS)
            Text("On the Mac: Audio MIDI Setup → Window → Show MIDI Network Setup → select “\(midi.networkSessionName)” under Directory → Connect. In Ableton, send to “Network Session 1”. USB MIDI (USB‑C cable or camera adapter) works as soon as it's plugged in. Bluetooth MIDI pedals and adapters: pair them with Bluetooth MIDI devices… (not in iOS Settings). StageCharts listens to every input.")
            #else
            Text("On the Mac: Audio MIDI Setup → Window → Show MIDI Network Setup → select “\(midi.networkSessionName)” under Directory → Connect. In Ableton, send to “Network Session 1”. USB MIDI works as soon as it's plugged in. Bluetooth MIDI: Audio MIDI Setup → Window → Show MIDI Studio → Bluetooth button → Connect. StageCharts listens to every input.")
            #endif
        }
    }

    private var omni: Bool { midi.mapping.listenChannel == 0 }

    private var listenSection: some View {
        Section {
            Picker("MIDI channel", selection: $midi.mapping.listenChannel) {
                Text("Omni (all)").tag(0)
                ForEach(1...16, id: \.self) { Text("Channel \($0)").tag($0) }
            }
        } header: {
            Text("Listen")
        } footer: {
            Text(omni ? "Omni: each trigger uses the channel it was learned on (shown as “Ch n”)."
                      : "All songs and actions listen on channel \(midi.mapping.listenChannel). Change this to match the channel Ableton sends on.")
        }
    }

    private var actionsSection: some View {
        Section {
            ForEach(StageAction.allCases) { action in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                        Text(midi.mapping.trigger(for: action)?.label(showChannel: omni) ?? "Not mapped")
                            .font(.caption.monospaced())
                            .foregroundStyle(midi.mapping.trigger(for: action) == nil ? Color.secondary : Color.chord)
                        if let extra = midi.mapping.extraBindings[action.rawValue] {
                            Text("also \(extra.label(showChannel: omni)) (MC8 StageCharts bank)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if midi.mapping.trigger(for: action) != nil {
                        Button { midi.mapping.assign(nil, to: action) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear")
                    }
                    learnButton(.action(action))
                }
            }
            Menu("Load preset…") {
                Button("OnSong-style (note C#-2/C-2 page, Breath CC 2 scroll)") {
                    midi.mapping.bindings = MIDIMapping.onSongPreset
                }
                Button("One CC per action (CC 20–28)") {
                    midi.mapping.bindings = MIDIMapping.ccPreset
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Tap Learn, then press the pedal/button or play the clip in Ableton. Notes, CCs and Program Changes can be learned. Scroll position must be a CC (its value 0–127 sets the position).")
        }
    }

    private var setSlotsSection: some View {
        Section {
            Toggle("CCs select songs by set position", isOn: $midi.mapping.setSlotsEnabled)
            if midi.mapping.setSlotsEnabled {
                Stepper(value: $midi.mapping.setSlotFirstCC, in: 0...(128 - midi.mapping.setSlotCount)) {
                    LabeledContent("First CC (song 1)", value: "CC \(midi.mapping.setSlotFirstCC)")
                }
                Stepper(value: $midi.mapping.setSlotCount, in: 1...30) {
                    LabeledContent("Number of songs", value: "\(midi.mapping.setSlotCount)")
                }
            }
        } header: {
            Text("Set list positions")
        } footer: {
            let m = midi.mapping
            Text("When a set list is loaded, CC \(m.setSlotFirstCC)–\(min(127, m.setSlotFirstCC + m.setSlotCount - 1)) open songs 1–\(m.setSlotCount) of that set, so Ableton never needs remapping week to week. These take priority over per-song messages below.")
        }
    }

    private var sendSection: some View {
        Section {
            Toggle("Send song changes to Ableton", isOn: $midi.mapping.sendSongChanges)
            if midi.mapping.sendSongChanges {
                Picker("Message", selection: $midi.mapping.sendKind) {
                    Text("Set position CC (CC \(midi.mapping.setSlotFirstCC)+)").tag(MIDIMapping.SendKind.setSlotCC)
                    Text("Program Change (position)").tag(MIDIMapping.SendKind.programChange)
                }
            }
        } header: {
            Text("Two-way MIDI")
        } footer: {
            Text("When you tap a song in the set on this device, StageCharts sends that message (on channel \(max(1, midi.mapping.listenChannel))) over the network session and its “StageCharts” MIDI output. In Ableton: enable Remote for that input, then MIDI-map the CC to the song’s scene. Changes that came from Ableton aren’t sent back.")
        }
    }

    private var clockSection: some View {
        Section {
            Picker("MIDI clock", selection: $midi.clockMode) {
                ForEach(MIDIClockMode.allCases) { Text($0.title).tag($0) }
            }
            switch midi.clockMode {
            case .off:
                EmptyView()
            case .send:
                HStack {
                    Text(midi.clockState.bpm.map { String(format: "%.0f BPM", $0) } ?? "–")
                        .font(.body.monospacedDigit())
                    Text(midi.clockState.running ? "Playing" : "Stopped").foregroundColor(.secondary)
                    Spacer()
                    Button("Start") { midi.clockStart() }
                    Button("Stop") { midi.clockStop() }
                }
                .buttonStyle(.bordered)
                Toggle("Send Start when a song is picked", isOn: $midi.clockStartOnSong)
            case .receive, .passThrough:
                HStack {
                    if let bpm = midi.clockState.bpm {
                        Text(String(format: "%.1f BPM", bpm)).font(.body.monospacedDigit())
                        Text(midi.clockState.running ? "Playing" : "Stopped").foregroundColor(.secondary)
                    } else {
                        Text("No clock coming in").foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("MIDI clock")
        } footer: {
            switch midi.clockMode {
            case .off: Text("Send, receive or pass through MIDI clock (24 per beat) with Start / Stop.")
            case .send: Text("StageCharts is the clock: it runs at the BPM of the song on screen and goes out over the network session and the “StageCharts” MIDI output. Set Ableton / Playback to follow external sync from that input. Start only goes out when you press Start (or pick a song, if turned on).")
            case .receive: Text("Shows the tempo and transport of a clock coming in on any MIDI input – e.g. Ableton with Sync turned on for the StageCharts output.")
            case .passThrough: Text("Clock, Start / Stop and song position coming in on any input are forwarded to StageCharts’ outputs (network session and the “StageCharts” MIDI output), so other gear can follow. Clock from the network session isn't sent back to it.")
            }
        }
    }

    private var songsSection: some View {
        Section {
            Toggle("Program Change selects song by list position", isOn: $midi.mapping.programChangeSelectsSong)
            let mapped = library.songs.filter {
                library.settings(for: $0.id).midiTrigger != nil || midi.learning == .song(id: $0.id) || pendingSongRow == $0.id
            }
            if mapped.isEmpty {
                Text("No songs have their own MIDI message. With set lists, CC \(midi.mapping.setSlotFirstCC)+ usually covers it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(mapped) { file in songMappingRow(file) }
            Button("Assign a song…", systemImage: "plus.circle") { pickingSong = true }
                .sheet(isPresented: $pickingSong) { songPicker }
        } header: {
            Text("Songs with their own MIDI message")
        } footer: {
            Text("For songs Ableton or Playback always select with the same message (e.g. a Playback song-start cue). Learn: tap, then fire the cue. Any CC, note or Program Change works.")
        }
    }

    private func songMappingRow(_ file: SongFile) -> some View {
        let trigger = library.settings(for: file.id).midiTrigger
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.song.title)
                Text(trigger?.label(showChannel: omni) ?? (midi.learning == .song(id: file.id) ? "Waiting for MIDI…" : "Not mapped"))
                    .font(.caption.monospaced())
                    .foregroundStyle(trigger == nil ? Color.secondary : Color.chord)
            }
            Spacer()
            Button { library.setTrigger(nil, for: file.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this song's MIDI message")
            Menu {
                Menu("Control Change") {
                    ForEach(0...127, id: \.self) { n in
                        Button(MIDITrigger(.controlChange, n).description) { setSong(file.id, .controlChange, n) }
                    }
                }
                Menu("Note") {
                    ForEach(0...127, id: \.self) { n in
                        Button("Note \(MIDITrigger.noteName(n))") { setSong(file.id, .note, n) }
                    }
                }
                Menu("Program Change") {
                    ForEach(1...128, id: \.self) { n in
                        Button("Program \(n)") { setSong(file.id, .programChange, n) }
                    }
                }
            } label: { Image(systemName: "slider.horizontal.3") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            learnButton(.song(id: file.id))
        }
    }

    /// Searchable list of all songs; choosing one starts Learn for it.
    private var songPicker: some View {
        NavigationStack {
            List(library.songs.filter { songSearch.isEmpty || $0.song.title.localizedCaseInsensitiveContains(songSearch) }) { file in
                Button {
                    pickingSong = false
                    songSearch = ""
                    midi.startLearning(.song(id: file.id))
                    pendingSongRow = file.id
                } label: {
                    HStack {
                        Text(file.song.title).foregroundStyle(.primary)
                        Spacer()
                        if let t = library.settings(for: file.id).midiTrigger {
                            Text(t.label(showChannel: omni)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $songSearch, prompt: "Search songs")
            .navigationTitle("Assign MIDI to a song")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pickingSong = false } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func setSong(_ id: String, _ kind: MIDITrigger.Kind, _ number: Int) {
        let trigger = MIDITrigger(kind, number)   // no channel: follows the listen channel
        midi.mapping.release(trigger)
        library.setTrigger(trigger, for: id)
    }

    private var monitorSection: some View {
        Section {
            if midi.log.isEmpty {
                Text("No MIDI received yet.").foregroundStyle(.secondary)
            }
            ForEach(midi.log) { entry in
                HStack {
                    Text(entry.message).monospaced()
                    Spacer()
                    Text(entry.result ?? "—")
                        .foregroundStyle(entry.result == nil ? Color.secondary : Color.chord)
                }
                .font(.callout)
            }
        } header: {
            HStack {
                Text("StageCharts actions")
                Spacer()
                Button("Clear") { midi.clearLog() }.font(.caption)
            }
        }
    }

    // MARK: Helpers

    private func learnButton(_ target: LearnTarget) -> some View {
        let active = midi.learning == target
        return Button { midi.startLearning(target) } label: {
            Text(active ? "Listening…" : "Learn")
                .frame(minWidth: 78)
        }
        .buttonStyle(.borderedProminent)
        .tint(active ? .orange : .gray)
    }

}

/// Sidebar row: a colored rounded icon tile and the category name (like System Settings).
@available(iOS 18, macOS 14, *)
private struct CategoryLabel: View {
    let category: SettingsView.Category
    var body: some View {
        Label {
            Text(category.title)
        } icon: {
            Image(systemName: category.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(category.color.gradient, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
