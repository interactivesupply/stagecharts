import SwiftUI
import UniformTypeIdentifiers
import ChordProKit

// MARK: - Settings → Helix

@available(iOS 18, macOS 14, *)
struct HelixSettingsSection: View {
    @EnvironmentObject var library: SongLibrary
    @AppStorage("helixSendSnapshots") private var sendSnapshots = true
    @AppStorage("helixChannel") private var channel = 1
    @AppStorage("helixVolumePedal") private var volumePedal = true
    @AppStorage("helixDriveKnob") private var driveKnob = true
    @AppStorage("helixKnobs") private var knobs = 3
    @AppStorage("helixSwitches") private var switches = 4
    @AppStorage("helixGuitarBlock") private var guitarBlock = true
    @AppStorage("helixEvenLevels") private var evenLevels = true
    @AppStorage("helixOutputLevel") private var outputLevel = 0.0
    @AppStorage("helixTwoDSP") private var twoDSP = true
    @ObservedObject private var guitars = GuitarStore.shared
    @EnvironmentObject var midi: MIDIController
    @State private var editingGuitar: MyGuitar?
    @State private var showingAbletonGuide = false
    @State private var catalog: HelixCatalog?
    @State private var scanning = false
    @State private var error: String?
    @State private var pickingFolder = false
    @State private var designing = false
    @State private var savedPresets: [HelixHistory] = []
    @State private var opening: HelixFileRef?
    private static let bookmarkKey = "helixPresetsBookmark"

    var body: some View {
        Group {
            Section {
                if let c = catalog {
                    LabeledContent("Learned from", value: "\(c.presetCount) presets · \(c.models.count) models")
                    LabeledContent("Last read", value: c.scanned.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Setting limits", value: c.limits.isEmpty ? "Not found" : "From Helix Native (\(c.limits.count) models)")
                } else {
                    Text("Not set up yet.").foregroundStyle(.secondary)
                }
                Button(catalog == nil ? "Choose presets folder…" : "Choose a different folder…") { chooseFolder() }
                if UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil {
                    Button(scanning ? "Reading…" : "Read presets again") { rescan() }.disabled(scanning)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            } header: {
                Text("Your Helix presets")
            } footer: {
                Text("StageCharts learns which amps and effects your Helix Native has, and every setting they take, from presets you've exported. In Helix Native select presets (or the whole factory setlist) and choose Export, into one folder; .hlx and .hls files both work. Include at least one preset saved by Helix Native. On a Mac with Helix Native installed, StageCharts also reads each setting's real limits from Helix Native itself.")
            }

            Section {
                Button("Make a preset from a description…", systemImage: "sparkles") { designing = true }
                ForEach(savedPresets, id: \.file) { h in
                    Button {
                        opening = HelixFileRef(id: h.file)
                    } label: {
                        LabeledContent {
                            Text("\(h.revisions.count) version\(h.revisions.count == 1 ? "" : "s")")
                        } label: {
                            Label(HelixBuilder.clean(h.current?.design.name ?? h.file, max: 16), systemImage: "slider.horizontal.3")
                        }
                    }
                }
                Button("Ableton setup guide…", systemImage: "book") { showingAbletonGuide = true }
                    .disabled(catalog == nil)
            } footer: {
                Text("For a whole set, use the set's menu: Helix preset for this set…  Saved presets are listed here: open one to change it with Claude, bring in your Helix Native edits, or go back to an earlier version.")
            }

            Section {
                Toggle("Start with my volume pedal on Knob 1", isOn: $volumePedal)
                Toggle("Knob 2 rides the drive pedal's gain", isOn: $driveKnob)
                Stepper("Knobs on my controller: \(knobs)", value: $knobs, in: 0...16)
                Stepper("Switches on my controller: \(switches)", value: $switches, in: 0...16)
            } header: {
                Text("Live controls")
            } footer: {
                Text("Helix Native's automation Knobs and Switches that your MIDI controller reaches (in Ableton, MIDI-map them on the Helix Native device). Each preset assigns them: Knob 1 to your volume pedal, the other knobs to settings worth riding, and the switches to effects worth turning on and off. The preset shows which is which.")
            }

            Section {
                Toggle("Even out levels", isOn: $evenLevels)
                Stepper("Preset output level: \(outputLevel > 0 ? "+" : "")\(outputLevel.formatted(.number.precision(.fractionLength(1)))) dB",
                        value: $outputLevel, in: -12...12, step: 0.5)
                Toggle("Use both DSPs (pedals on DSP 1, amps on DSP 2)", isOn: $twoDSP)
            } header: {
                Text("Levels and layout")
            } footer: {
                Text("Even out levels brings each amp's channel volume up so its loudest snapshot sits at 0.85 (quieter snapshots stay proportionally quieter; Master is left alone) and puts cabs at +2.5 dB, like hand-built presets. The output level is the preset's main output gain: nudge it until new presets match one of yours. Both apply to presets made from now on.")
            }

            MC8Section()

            Section {
                Toggle("Add a guitar block that matches my guitar", isOn: $guitarBlock)
                Picker("Usual guitar", selection: $guitars.defaultID) {
                    ForEach(guitars.guitars) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                ForEach(guitars.guitars) { g in
                    Button { editingGuitar = g } label: {
                        LabeledContent {
                            Text(String(format: "level %+.1f · low %+.1f · high %+.1f dB", g.level, g.low, g.high))
                                .font(.caption.monospacedDigit())
                        } label: {
                            Text(g.name)
                            if !g.pickups.isEmpty { Text(g.pickups).font(.caption) }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            guitars.guitars.removeAll { $0.id == g.id }
                        }
                    }
                }
                .onDelete { guitars.guitars.remove(atOffsets: $0) }
                Button("Add a guitar…", systemImage: "plus") {
                    let g = MyGuitar(name: "New guitar", pickups: "")
                    guitars.guitars.append(g)
                    editingGuitar = g
                }
                if guitarBlock {
                    HStack {
                        Text("For mapping in Ableton:").font(.caption).foregroundStyle(.secondary)
                        ForEach(HelixBuilder.guitarKnobs, id: \.knob) { k in
                            Button("CC \(k.knob)") { midi.sendHelixCC(k.knob, 64) }
                                .help("Sends CC \(k.knob) once so Ableton can learn it for Knob \(k.knob) (\(k.name))")
                        }
                    }
                }
            } header: {
                Text("Guitars")
            } footer: {
                Text("Claude voices each preset to work across these guitars. With the guitar block on, every new preset starts with a Low/High Shelf EQ whose level, low and high follow Helix Native's Knobs 14, 15 and 16, and StageCharts sets them for the guitar you're playing whenever a song opens (CC 14–16 on the Helix channel). Pick the guitar from a set's menu, or per song in the set list. Click a guitar to tune it by ear. One-time setup in Ableton: MIDI-map Knobs 14, 15 and 16 on the Helix Native device, clicking the matching CC button above for each.")
            }
            .sheet(item: $editingGuitar) { g in GuitarEditor(guitar: g) }
            .sheet(isPresented: $showingAbletonGuide) { AbletonSetupGuide() }

            Section {
                Toggle("Recall the song's snapshot when it opens", isOn: $sendSnapshots)
                Stepper("Helix Native MIDI channel: \(channel)", value: $channel, in: 1...16)
            } header: {
                Text("Snapshots")
            } footer: {
                Text("Sends CC 69 (0 = snapshot 1) on the \"StageCharts\" MIDI output and the network session. In Ableton, use the Helix Native AU (Audio Units). Add a MIDI track with MIDI From: StageCharts, Monitor: In, and MIDI To: the Helix Native track → Helix Native.")
            }
        }
        .onAppear { catalog = HelixCatalog.load(from: library.helixFolder) }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { use(url) }
        }
        .sheet(isPresented: $designing, onDismiss: loadSavedPresets) { HelixPresetView(setID: nil) }
        .sheet(item: $opening, onDismiss: loadSavedPresets) { HelixPresetView(setID: nil, file: $0.id) }
        .task { loadSavedPresets() }
    }

    private func loadSavedPresets() { savedPresets = HelixHistory.all(in: library.helixFolder) }

    private func chooseFolder() {
        #if os(macOS)
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose the folder with your exported Helix Native presets"
        if p.runModal() == .OK, let u = p.url { use(u) }
        #else
        pickingFolder = true
        #endif
    }

    private func use(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        if let b = try? url.bookmarkData() { UserDefaults.standard.set(b, forKey: Self.bookmarkKey) }
        scan(url) { if scoped { url.stopAccessingSecurityScopedResource() } }
    }

    private func rescan() {
        guard let d = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: d, bookmarkDataIsStale: &stale) else {
            error = "That folder can't be found any more. Choose it again."; return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        scan(url) { if scoped { url.stopAccessingSecurityScopedResource() } }
    }

    private func scan(_ url: URL, done: @escaping () -> Void) {
        scanning = true; error = nil
        let dest = library.helixFolder
        Task.detached {
            let result = Result {
                var c = try HelixCatalog.scan(url)
                c.info = HelixCatalog.readInfo(in: dest)   // model descriptions live in the library's Helix folder
                HelixCatalog.shared = c
                return c
            }
            if case .success(let c) = result { try? c.save(in: dest) }
            await MainActor.run {
                switch result {
                case .success(let c): catalog = c
                case .failure(let e): error = e.localizedDescription
                }
                scanning = false
                done()
                library.onLocalChange?()
            }
        }
    }
}

// MARK: - Designing a preset

/// A saved preset file, for opening its history in a sheet.
struct HelixFileRef: Identifiable { var id: String }

@available(iOS 18, macOS 14, *)
struct HelixPresetView: View {
    let setID: UUID?
    /// A saved preset to open (its history), when not opened from a set.
    var file: String? = nil
    @EnvironmentObject var library: SongLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage("helixLastDescription") private var request = "A big crunchy tone with a dotted-eighth delay and a boost for leads"
    @State private var notes: [UUID: String] = [:]
    @State private var working = false
    @State private var error: String?
    @State private var design: HelixDesign?
    @State private var built: HelixBuilder.Result?
    @State private var saved: URL?
    @AppStorage("helixResearch") private var researchOnline = true
    @AppStorage("helixModel") private var model = Claude.model
    @AppStorage("helixEffort") private var effort = "high"
    @State private var stage = ""
    @State private var research: String?
    /// The preset's versions, once it has been saved (or when opening one that has a history).
    @State private var history: HelixHistory?
    @State private var change = ""
    @State private var pendingKind: HelixHistory.Revision.Kind = .design
    @State private var pendingRequest = ""
    @State private var importing = false
    @State private var importNotes: [String] = []

    private static let efforts: [(String, String)] = [
        ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high"), ("max", "Max"),
    ]

    private var set: SetList? { library.setList(id: setID) }
    private var catalog: HelixCatalog? { HelixCatalog.load(from: library.helixFolder) }

    var body: some View {
        NavigationStack {
            Form {
                if catalog == nil {
                    Section {
                        Label("Choose your Helix presets folder in Settings → Helix first, so StageCharts knows which amps and effects you have.",
                              systemImage: "exclamationmark.triangle")
                    }
                }
                if let history { historySections(history) }
                Section {
                    TextEditor(text: $request).frame(minHeight: 90)
                } header: {
                    Text(history == nil ? "Describe the tones" : "Or start over: describe the tones")
                } footer: {
                    Text("E.g. \"big crunchy tone with a dotted-eighth delay and a boost\", \"ambient swells for the slow songs\", \"match the electric guitar on Gratitude by Brandon Lake\".")
                }
                Section {
                    Toggle("Research the recordings' guitar tones online", isOn: $researchOnline)
                    Picker("Model", selection: $model) {
                        ForEach(Claude.choices, id: \.id) { c in Text("\(c.name) – \(c.note)").tag(c.id) }
                    }
                    Picker("Effort", selection: $effort) {
                        ForEach(Self.efforts, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text("Research: Claude first searches the web for rig rundowns and tone guides for the songs in this set and any recording you name, then builds the preset from what it finds. It adds a minute or two and a little cost (web searches are billed per search). Higher effort thinks longer: better on complicated sets, slower and costlier. High suits most presets.")
                }
                if let set {
                    Section {
                        ForEach(set.items) { item in
                            if let f = library.song(id: item.songID) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(f.song.title).font(.headline)
                                        Spacer()
                                        Text(songFacts(item, f)).font(.caption).foregroundStyle(.secondary)
                                        if let n = built?.songSnapshots[index(of: item)], let names = built?.snapshotNames,
                                           names.indices.contains(n) {
                                            Text(names[n]).font(.caption.weight(.semibold))
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                        }
                                    }
                                    TextField("Notes for this song (optional), e.g. \"swells in the verse\"",
                                              text: Binding(get: { notes[item.id] ?? "" }, set: { notes[item.id] = $0 }))
                                        .font(.callout)
                                }
                            }
                        }
                    } header: {
                        Text("Songs in \(set.name) – one snapshot each (up to 8)")
                    }
                }
                Section {
                    Button {
                        Task { await run() }
                    } label: {
                        if working { HStack { ProgressView(); Text(stage) } }
                        else { Label(history != nil ? "Design a new version from scratch" : built == nil ? "Design preset" : "Design again",
                                     systemImage: "sparkles") }
                    }
                    .disabled(working || catalog == nil || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                } footer: {
                    Text("Your description, the song titles/keys/tempos and the list of your Helix models are sent to Anthropic with your API key."
                         + (researchOnline ? " The song titles and your description are also used for web searches." : ""))
                }
                if let design, let built { result(design, built) }
            }
            .formStyle(.grouped)
            .task { loadHistory() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { r in
                if case .success(let url) = r { importEdits(from: url) }
            }
            #if DEBUG
            .task { if ProcessInfo.processInfo.arguments.contains("-mockHelix") { await run() } }
            #endif
            .navigationTitle(set == nil ? "Helix preset" : "Helix preset for this set")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 640)
        #endif
    }

    @ViewBuilder private func result(_ d: HelixDesign, _ b: HelixBuilder.Result) -> some View {
        Section {
            Text(HelixBuilder.clean(d.name, max: 16)).font(.title3.weight(.semibold))
            Text(d.summary).font(.callout)
            ForEach(Array(b.blocks.enumerated()), id: \.offset) { i, name in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                    Text(name)
                    if let why = d.blocks.first(where: { HelixCatalog.describe($0.model) == name })?.why {
                        Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        } header: {
            Text("Preset")
        }
        Section("Snapshots") {
            ForEach(Array(b.snapshotNames.enumerated()), id: \.offset) { i, name in
                let songs = (set?.items ?? []).enumerated().filter { b.songSnapshots[$0.offset] == i }
                    .compactMap { library.song(id: $0.element.songID)?.song.title }
                LabeledContent("\(i + 1). \(name)", value: songs.isEmpty ? "–" : songs.joined(separator: ", "))
            }
        }
        if let research, !research.isEmpty {
            Section {
                DisclosureGroup("What Claude found about the recordings") {
                    Text(research).font(.callout).textSelection(.enabled)
                }
            }
        }
        if !b.controls.isEmpty {
            Section {
                ForEach(b.controls, id: \.self) { Text($0) }
            } header: {
                Text("Live controls")
            } footer: {
                Text("Already assigned in the preset: your controller's knobs and switches work as soon as it loads.")
            }
        }
        if !b.warnings.isEmpty || !importNotes.isEmpty {
            Section("Notes") { ForEach(importNotes + b.warnings, id: \.self) { Text($0).font(.caption) } }
        }
        Section {
            if let saved {
                Label("Saved as \(saved.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                #if os(macOS)
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                #endif
                ShareLink(item: saved) { Label("Share or save the .hlx…", systemImage: "square.and.arrow.up") }
            } else {
                Button(history.map { "Save as version \($0.revisions.count + 1)" }
                       ?? (set == nil ? "Save preset" : "Save preset and use it for this set"),
                       systemImage: "square.and.arrow.down") { save(d, b) }
                    .buttonStyle(.borderedProminent)
            }
        } footer: {
            Text("Then in Helix Native: Import (or drag the .hlx onto the preset list) and pick it. "
                 + (set == nil ? "" : "Opening a song in this set recalls its snapshot."))
        }
    }

    private func index(of item: SetItem) -> Int { set?.items.firstIndex { $0.id == item.id } ?? -1 }

    private func songFacts(_ item: SetItem, _ f: SongFile) -> String {
        let r = RenderedSong(file: f, semitones: item.semitones ?? library.settings(for: f.id).semitones, capo: 0,
                             tempo: library.settings(for: f.id).tempo)
        return [r.soundingKey?.description, library.tempo(for: f).map { "\($0) BPM" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var songs: [HelixSong] {
        (set?.items ?? []).compactMap { item in
            guard let f = library.song(id: item.songID) else { return nil }
            let r = RenderedSong(file: f, semitones: item.semitones ?? library.settings(for: f.id).semitones, capo: 0,
                                 tempo: library.settings(for: f.id).tempo)
            return HelixSong(title: f.song.title, artist: f.song.artists.first, key: r.soundingKey?.description,
                             bpm: library.tempo(for: f), time: f.song.time, note: notes[item.id] ?? "")
        }
    }

    /// Settings → Helix → Guitars: whether to add the guitar block, and the guitars for Claude.
    static var guitarSetup: (Bool, [String]) {
        (UserDefaults.standard.object(forKey: "helixGuitarBlock") as? Bool ?? true, GuitarStore.shared.guitars.map(\.promptLine))
    }

    /// Settings → Helix → Live controls.
    static var liveControls: (Bool, Int, Int) {
        let u = UserDefaults.standard
        return (u.object(forKey: "helixVolumePedal") as? Bool ?? true, u.object(forKey: "helixKnobs") as? Int ?? 3,
                u.object(forKey: "helixSwitches") as? Int ?? 4)
    }

    private func run() async {
        guard let catalog else { return }
        working = true; error = nil; saved = nil
        defer { working = false }
        do {
            let s = songs
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-mockHelix") {      // screenshots without calling Claude
                let d = HelixDesign.mock(catalog: catalog, songs: s.count)
                let (pedal, knobs, switches) = Self.liveControls
                built = try HelixBuilder.build(d, catalog: catalog, songCount: s.count, volumePedal: pedal,
                                               knobs: knobs, switches: switches, guitarBlock: Self.guitarSetup.0)
                design = d; return
            }
            #endif
            let (pedal, knobs, switches) = Self.liveControls
            research = nil
            if researchOnline {
                stage = "Researching the recordings… (a minute or two)"
                research = try await HelixDesigner.research(description: request, songs: s, model: model, effort: effort)
            }
            stage = "Designing… (about a minute)"
            let (guitarBlock, guitarLines) = Self.guitarSetup
            let d = try await HelixDesigner.design(description: request, songs: s, catalog: catalog, volumePedal: pedal,
                                                   knobs: knobs, switches: switches, research: research,
                                                   model: model, effort: effort, guitarBlock: guitarBlock, guitars: guitarLines)
            built = try HelixBuilder.build(d, catalog: catalog, songCount: s.count, volumePedal: pedal,
                                           knobs: knobs, switches: switches, guitarBlock: guitarBlock)
            design = d
            pendingKind = .design; pendingRequest = request; importNotes = []
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: History

    @ViewBuilder private func historySections(_ h: HelixHistory) -> some View {
        Section {
            if let cur = h.current {
                LabeledContent(HelixBuilder.clean(cur.design.name, max: 16),
                               value: "version \(h.revisions.count) · \(cur.date.formatted(date: .abbreviated, time: .shortened))")
            }
            TextEditor(text: $change).frame(minHeight: 70)
            Button {
                Task { await makeChange() }
            } label: {
                if working { HStack { ProgressView(); Text(stage) } }
                else { Label("Make this change", systemImage: "wand.and.stars") }
            }
            .disabled(working || catalog == nil || change.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if h.changedOutside(in: library.helixFolder) {
                Label("\(h.file) changed after StageCharts saved it.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                Button("Read my edits from it", systemImage: "arrow.down.doc") {
                    importEdits(from: library.helixFolder.appendingPathComponent(h.file))
                }
            }
            Button("Import edits from a preset exported from Helix Native…", systemImage: "square.and.arrow.down.on.square") {
                importing = true
            }
        } header: {
            Text("Change this preset")
        } footer: {
            Text("E.g. \"less gain in the verse snapshot\", \"swap the plate for a shimmer\", \"put a tremolo on Switch 4\". "
                 + "Claude changes only that and keeps the rest. If you've tweaked the preset in Helix Native, export it "
                 + "and import it here first, so the change builds on your edits.")
        }
        Section {
            ForEach(Array(h.revisions.enumerated().reversed()), id: \.element.id) { i, r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(i + 1). \(Self.kindName(r.kind))").font(.callout.weight(.semibold))
                        Spacer()
                        Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(r.request).font(.callout).lineLimit(3)
                    if let line = r.settings { Text(line).font(.caption2).foregroundStyle(.secondary) }
                    if i < h.revisions.count - 1 {
                        Button("Go back to this version") { restore(r, number: i + 1) }.font(.caption).disabled(working)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Versions")
        } footer: {
            Text("Each saved version keeps its request and Claude's design, in \(HelixHistory.url(for: h.file, in: library.helixFolder).lastPathComponent) next to the preset.")
        }
    }

    private static func kindName(_ k: HelixHistory.Revision.Kind) -> String {
        switch k {
        case .design: return "Designed"
        case .change: return "Changed"
        case .imported: return "Your Helix Native edits"
        case .restored: return "Went back"
        }
    }

    private func rebuild(_ d: HelixDesign) throws -> HelixBuilder.Result {
        guard let catalog else { throw HelixError.bad("Choose your Helix presets folder in Settings → Helix first.") }
        let (pedal, knobs, switches) = Self.liveControls
        return try HelixBuilder.build(d, catalog: catalog, songCount: songs.count, volumePedal: pedal,
                                      knobs: knobs, switches: switches, guitarBlock: Self.guitarSetup.0)
    }

    private func loadHistory() {
        guard history == nil, let f = file ?? set?.helixPreset,
              let h = HelixHistory.load(file: f, in: library.helixFolder), let cur = h.current else { return }
        history = h
        design = cur.design
        research = cur.research
        if !h.description.isEmpty { request = h.description }
        for (k, v) in cur.songNotes ?? [:] { if let id = UUID(uuidString: k) { notes[id] = v } }
        built = try? rebuild(cur.design)
        saved = library.helixFolder.appendingPathComponent(h.file)
    }

    private func makeChange() async {
        guard let catalog, let h = history, let base = design ?? h.current?.design else { return }
        let ask = change.trimmingCharacters(in: .whitespacesAndNewlines)
        working = true; error = nil
        defer { working = false }
        do {
            var log = h.requestLog
            if saved == nil, !pendingRequest.isEmpty { log.append("Not saved yet: \(pendingRequest)") }
            stage = "Making the change… (about a minute)"
            let (pedal, knobs, switches) = Self.liveControls
            let (guitarBlock, guitarLines) = Self.guitarSetup
            let d = try await HelixDesigner.design(description: h.description, songs: songs, catalog: catalog,
                                                   volumePedal: pedal, knobs: knobs, switches: switches, research: research,
                                                   model: model, effort: effort, guitarBlock: guitarBlock, guitars: guitarLines,
                                                   revision: .init(current: base, history: log, change: ask))
            built = try rebuild(d)
            design = d
            pendingRequest = (saved == nil && pendingKind == .change && !pendingRequest.isEmpty)
                ? pendingRequest + "; then " + ask : ask
            pendingKind = .change
            importNotes = []
            saved = nil
            change = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore(_ r: HelixHistory.Revision, number: Int) {
        do {
            built = try rebuild(r.design)
            design = r.design
            research = r.research
            pendingKind = .restored
            pendingRequest = "Went back to version \(number) (\(r.date.formatted(date: .abbreviated, time: .omitted))): \(r.request)"
            importNotes = []
            saved = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importEdits(from url: URL) {
        guard let catalog else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let preset = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let r = HelixImport.design(from: preset, catalog: catalog, previous: design ?? history?.current?.design) else {
            error = "Couldn't read a Helix preset from \(url.lastPathComponent)."; return
        }
        do {
            built = try rebuild(r.design)
            design = r.design
            importNotes = r.notes + ["Read your edits from \(url.lastPathComponent). Save them as a version before making more changes."]
            pendingKind = .imported
            pendingRequest = "Your edits from Helix Native (\(url.lastPathComponent))"
            saved = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ d: HelixDesign, _ b: HelixBuilder.Result) {
        do {
            let url = try HelixBuilder.save(b.preset, name: d.name, in: library.helixFolder, replacing: history?.file)
            saved = url
            var h = history ?? HelixHistory(file: url.lastPathComponent)
            let (pedal, knobs, switches) = Self.liveControls
            let ai = pendingKind == .design || pendingKind == .change
            h.revisions.append(.init(kind: pendingKind, request: pendingRequest.isEmpty ? request : pendingRequest, design: d,
                                     research: research, model: ai ? model : nil, effort: ai ? effort : nil,
                                     songNotes: Dictionary(uniqueKeysWithValues: notes.filter { !$0.value.isEmpty }
                                        .map { ($0.key.uuidString, $0.value) }),
                                     settings: HelixHistory.settingsLine(volumePedal: pedal, knobs: knobs, switches: switches,
                                                                         guitarBlock: Self.guitarSetup.0)))
            try h.save(in: library.helixFolder)
            history = h
            pendingRequest = ""; importNotes = []
            if let set {
                library.updateSet(set.id) { s in
                    s.helixPreset = url.lastPathComponent
                    s.helixSnapshotNames = b.snapshotNames
                    for i in s.items.indices { s.items[i].helixSnapshot = b.songSnapshots[i] }
                }
            } else {
                library.onLocalChange?()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#if DEBUG
extension HelixDesign {
    static func mock(catalog: HelixCatalog, songs: Int) -> HelixDesign {
        func pick(_ p: String) -> String { catalog.models.keys.sorted().first { $0.hasPrefix(p) } ?? catalog.models.keys.sorted()[0] }
        let blocks = [pick("HD2_DistKinky"), pick("HD2_AmpPlacater"), pick("HD2_CabMicIr"), pick("HD2_DelaySimple"), pick("HD2_ReverbPlate")]
        return HelixDesign(name: "Sunday Crunch", blocks: blocks.map { .init(model: $0, settings: [], why: "Mock block") },
                           snapshots: [.init(name: "Crunch", tempo: 72, enabled: [false, true, true, true, true], settings: []),
                                       .init(name: "Lead", tempo: 130, enabled: [true, true, true, true, true], settings: [])],
                           songs: (0..<songs).map { .init(song: $0, snapshot: $0 % 2) },
                           summary: "Mock design for screenshots: a crunchy amp with a boost for leads and a dotted-eighth delay.")
    }
}
#endif

// MARK: - Tuning a guitar by ear

@available(iOS 18, macOS 14, *)
struct GuitarEditor: View {
    @State var guitar: MyGuitar
    @ObservedObject private var store = GuitarStore.shared
    @EnvironmentObject var midi: MIDIController
    @Environment(\.dismiss) private var dismiss
    @State private var live = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $guitar.name)
                    TextField("Pickups and character, e.g. \"three single coils; bright, low output\"", text: $guitar.pickups,
                              axis: .vertical)
                } footer: {
                    Text("Claude reads the pickups line when it voices presets.")
                }
                Section {
                    slider("Level", $guitar.level, "More for quieter pickups (single coils), so drives and amps react the same.")
                    slider("Low (150 Hz shelf)", $guitar.low, "Adds or trims body and boom.")
                    slider("High (3 kHz shelf)", $guitar.high, "Tames ice-pick single coils or opens up dark humbuckers.")
                    Toggle("Hear changes while adjusting", isOn: $live)
                    Button("Reset to 0 dB", systemImage: "arrow.counterclockwise") {
                        guitar.level = 0; guitar.low = 0; guitar.high = 0
                    }
                } header: {
                    Text("Guitar block")
                } footer: {
                    Text("Load a preset made with the guitar block in Helix Native, play this guitar, and adjust until it sits like your others. Changes go to Knobs 14–16 as you move the sliders.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(guitar.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.update(guitar); midi.sendHelixGuitar(guitar); dismiss() }
                }
            }
            .onChange(of: guitar) { _, g in if live { midi.sendHelixGuitar(g) } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 460)
        #endif
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: String(format: "%+.1f dB", value.wrappedValue))
            Slider(value: value, in: -HelixBuilder.guitarRange...HelixBuilder.guitarRange, step: 0.5)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Ableton setup guide

/// The one-time Ableton setup for StageCharts + Helix Native, with the player's current channel and counts filled in.
@available(iOS 18, macOS 14, *)
struct AbletonSetupGuide: View {
    @EnvironmentObject var midi: MIDIController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("helixChannel") private var channel = 1
    @AppStorage("helixVolumePedal") private var volumePedal = true
    @AppStorage("helixKnobs") private var knobs = 3
    @AppStorage("helixSwitches") private var switches = 4
    @AppStorage("helixGuitarBlock") private var guitarBlock = true
    @AppStorage("helixSendSnapshots") private var sendSnapshots = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    step(1, "Ableton → Settings → Link, Tempo & MIDI. Under MIDI Ports, find Input: StageCharts and turn on Track and Remote (and Sync if StageCharts sends the clock).")
                    step(2, "Use the Helix Native AU (Audio Units) plug-in on your guitar track.")
                    step(3, "Add a MIDI track: MIDI From → StageCharts, Monitor → In, MIDI To → your guitar track → Helix Native. This carries StageCharts' messages to Helix Native.")
                } header: {
                    Text("1. Connect StageCharts to Helix Native")
                } footer: {
                    Text("On another device (iPad), StageCharts sends over the network session instead: connect it in Audio MIDI Setup → MIDI Network Setup, and use Network Session 1 in place of StageCharts above.")
                }

                Section {
                    step(1, "Click MIDI in Ableton's top-right corner (⌘M) to enter MIDI Map mode.")
                    step(2, "Click the Helix Native setting below on the device's mapping list (in the plug-in's expanded parameter view), then press the matching Send button here. Ableton learns it.")
                    step(3, "Click MIDI again to leave MIDI Map mode. Repeat whenever you rebuild the Ableton set.")
                    mapRow("Snapshot Index", "CC 69", "Recalls each song's snapshot when it opens" + (sendSnapshots ? "" : " (turned off in Settings → Helix)")) {
                        midi.sendHelixCC(69, 0)
                    }
                    ForEach(HelixBuilder.guitarKnobs, id: \.knob) { k in
                        mapRow("Knob \(k.knob)", "CC \(k.knob)", "Guitar \(k.name), set for the guitar you're playing"
                               + (guitarBlock ? "" : " (guitar block turned off)")) { midi.sendHelixCC(k.knob, 64) }
                    }
                } header: {
                    Text("2. Map StageCharts' messages (channel \(channel))")
                } footer: {
                    Text("The channel is the Helix Native MIDI channel in Settings → Helix. Each Send button sends that message once (snapshot 1, or the middle value for a guitar knob).")
                }

                Section {
                    if volumePedal {
                        LabeledContent("Knob 1", value: "your volume (expression) pedal")
                    }
                    let first = volumePedal ? 2 : 1
                    let last = HelixBuilder.lastAIKnob(knobs, guitarBlock: guitarBlock)
                    if last >= first {
                        LabeledContent(first == last ? "Knob \(first)" : "Knobs \(first)–\(last)", value: "knobs or faders on your controller")
                    }
                    if switches > 0 {
                        LabeledContent(switches == 1 ? "Switch 1" : "Switches 1–\(switches)", value: "footswitches on your controller")
                    }
                } header: {
                    Text("3. Map your own controller (once)")
                } footer: {
                    Text("In MIDI Map mode, click each Helix Native Knob or Switch, then move the pedal, knob or switch on your controller. AI presets assign these the same way every time, so the map never changes; each preset lists what they do under Live controls. Counts come from Settings → Helix → Live controls.")
                }

                Section {
                    step(1, "Open a song in a set that has a Helix preset: Helix Native should change snapshot.")
                    step(2, "Settings → MIDI → monitor shows each message StageCharts sent, e.g. \"→ sent CC 69 = 0 ch \(channel)\".")
                    step(3, "Nothing happens? Check Remote is on for the StageCharts input, the MIDI track's Monitor is In, and the channel here matches the one you mapped.")
                } header: {
                    Text("4. Check it")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Ableton setup")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }

    private func mapRow(_ target: String, _ cc: String, _ what: String, send: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(target) ← \(cc)")
                Text(what).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Send \(cc)", action: send)
        }
    }
}


/// Settings → Helix → Morningstar MC8: label the StageCharts bank's switch presets for each song.
struct MC8Section: View {
    @EnvironmentObject var midi: MIDIController
    @ObservedObject private var mc8 = MC8Link.shared
    @AppStorage(MC8Link.enabledKey) private var enabled = false
    @AppStorage(MC8Link.outputKey) private var output = 0
    @AppStorage(MC8Link.bankKey) private var bank = "StageCharts"

    var body: some View {
        Section {
            Toggle("Label the MC8's switches for each song", isOn: $enabled)
            if enabled {
                Picker("MC8 is on", selection: $output) {
                    Text("Choose…").tag(0)
                    ForEach(midi.outputs) { o in Text(o.name).tag(Int(o.id)) }
                }
                TextField("Bank name", text: $bank)
                HStack { Text("Status"); Spacer(); Text(mc8.status).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
                Button("Check MC8") { mc8.check() }
            }
        } header: {
            Text("Morningstar MC8")
        } footer: {
            Text("For the MC8's “\(bank)” bank: A = page down (CC 80), E = page up (CC 81), B C D F G H = Switches 1–6 (CC 49–54 on channel 2). When a song opens, StageCharts names B–D and F–H after what the set's Helix preset put on Switches 1–6, with OFF / ON showing the switch's position (e.g. “Scream OFF”, “Scream ON”). Names are only sent when the MC8 is on that bank, and aren't saved, so other banks are never changed. Close the Morningstar Editor while playing – it can undo the names.")
        }
    }
}
