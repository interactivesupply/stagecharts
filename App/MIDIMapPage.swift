import SwiftUI
import StageMIDI

// MARK: - The rig's MIDI map

/// What each program in the rig listens for (Ableton, Playback, a Morningstar MC8…), written down once so the whole rig
/// is documented in one place. Kept in the library ("midi-map.json") so it syncs to every device. StageCharts' own
/// part is read live from its settings rather than stored.
struct RigMIDIMap: Codable, Equatable {
    struct Row: Codable, Identifiable, Equatable {
        var id = UUID()
        var channel: Int            // 1–16
        var message: String         // "CC 14", "CC 49–54", "Note C3", "Program 5"
        var target: String          // "Helix Native · Knob 14"
        var detail: String = ""     // "guitar EQ level, set by StageCharts"
    }
    struct App: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var note: String = ""
        var rows: [Row] = []
    }
    var apps: [App] = []

    static let fileName = "midi-map.json"
    static func url(in base: URL) -> URL { base.appendingPathComponent(fileName) }

    static func load(from base: URL) -> RigMIDIMap {
        guard let d = try? Data(contentsOf: url(in: base)),
              let m = try? JSONDecoder().decode(RigMIDIMap.self, from: d) else { return RigMIDIMap() }
        return m
    }

    func save(to base: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url(in: base), options: .atomic)
    }
}

/// One line of the map, for StageCharts' live part and the channel overview.
struct MIDIMapLine: Identifiable {
    var id = UUID()
    var channel: Int?               // nil = any channel / not channel-based
    var message: String
    var target: String
    var detail: String = ""
}

// MARK: - Page

/// Settings → MIDI map.
@available(iOS 16, macOS 13, *)
struct MIDIMapPage: View {
    @ObservedObject var midi: MIDIController
    @EnvironmentObject var library: SongLibrary
    @State private var map = RigMIDIMap()
    @State private var editingRow: RowEdit?
    @State private var editingApp: RigMIDIMap.App?
    @State private var error: String?

    @AppStorage("helixChannel") private var helixChannel = 1
    @AppStorage("helixSendSnapshots") private var helixSnapshots = true
    @AppStorage("helixGuitarBlock") private var helixGuitarBlock = true
    @AppStorage(MC8Link.enabledKey) private var mc8Labels = false

    struct RowEdit: Identifiable { var id: UUID { row.id }; var app: UUID; var row: RigMIDIMap.Row; var isNew: Bool }

    var body: some View {
        Group {
            overview
            Section {
                ForEach(stageChartsReceives) { line($0) }
            } header: {
                Text("StageCharts listens for")
            } footer: {
                Text("From its MIDI inputs and the network session. Change these in MIDI control.")
            }
            Section {
                let sends = stageChartsSends
                if sends.isEmpty { Text("Nothing (Helix, song changes and MIDI routes are off)").foregroundStyle(.secondary) }
                ForEach(sends) { line($0) }
            } header: {
                Text("StageCharts sends")
            } footer: {
                Text("On its “StageCharts” MIDI output and the network session; routes go where each one says. Change these in Helix, MIDI control and MIDI connections.")
            }
            ForEach(map.apps) { app in appSection(app) }
            Section {
                Button("Add a program or device…", systemImage: "plus") {
                    editingApp = RigMIDIMap.App(name: "")
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            } footer: {
                Text("Write down what each program in your rig listens for (Ableton's MIDI Mappings list, Playback's MIDI Mapping, your MC8's presets). Saved in your library, so every device shows the same map.")
            }
        }
        .onAppear { map = RigMIDIMap.load(from: library.base) }
        .sheet(item: $editingRow) { e in
            RowEditor(edit: e) { row in
                update { m in
                    guard let a = m.apps.firstIndex(where: { $0.id == e.app }) else { return }
                    if let i = m.apps[a].rows.firstIndex(where: { $0.id == row.id }) { m.apps[a].rows[i] = row }
                    else { m.apps[a].rows.append(row) }
                    m.apps[a].rows.sort { ($0.channel, Self.sortKey($0.message)) < ($1.channel, Self.sortKey($1.message)) }
                }
            } onDelete: {
                update { m in
                    guard let a = m.apps.firstIndex(where: { $0.id == e.app }) else { return }
                    m.apps[a].rows.removeAll { $0.id == e.row.id }
                }
            }
        }
        .sheet(item: $editingApp) { app in
            AppEditor(app: app, isNew: !map.apps.contains { $0.id == app.id }) { a in
                update { m in
                    if let i = m.apps.firstIndex(where: { $0.id == a.id }) { m.apps[i] = a } else { m.apps.append(a) }
                }
            } onDelete: {
                update { m in m.apps.removeAll { $0.id == app.id } }
            }
        }
    }

    // MARK: Sections

    /// Which channels each program uses, to spot two programs answering the same channel.
    private var overview: some View {
        var byChannel: [Int: [String]] = [:]
        func add(_ ch: Int?, _ who: String) {
            guard let ch else { return }
            if !(byChannel[ch] ?? []).contains(who) { byChannel[ch, default: []].append(who) }
        }
        for l in stageChartsReceives { add(l.channel, "StageCharts") }
        for a in map.apps { for r in a.rows { add(r.channel, a.name) } }
        let omni = midi.mapping.listenChannel == 0
        return Section {
            if byChannel.isEmpty && !omni { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(byChannel.keys.sorted(), id: \.self) { ch in
                let who = byChannel[ch] ?? []
                HStack {
                    Text("Ch \(ch)").font(.callout.monospacedDigit().weight(.semibold)).frame(width: 50, alignment: .leading)
                    Text(who.joined(separator: " · "))
                    Spacer()
                    if who.count > 1 {
                        Label("shared", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if omni { Text("StageCharts listens on every channel (omni).").font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text("Channels")
        } footer: {
            Text("Who listens on each channel. A shared channel is fine when the messages differ, but a CC both programs map will trigger both.")
        }
    }

    @ViewBuilder private func appSection(_ app: RigMIDIMap.App) -> some View {
        Section {
            if app.rows.isEmpty { Text("No mappings yet.").foregroundStyle(.secondary) }
            ForEach(app.rows) { r in
                Button {
                    editingRow = RowEdit(app: app.id, row: r, isNew: false)
                } label: {
                    line(MIDIMapLine(channel: r.channel, message: r.message, target: r.target, detail: r.detail))
                }
                .buttonStyle(.plain)
            }
            Button("Add mapping", systemImage: "plus") {
                let last = app.rows.last
                editingRow = RowEdit(app: app.id, row: .init(channel: last?.channel ?? 1, message: "CC ", target: ""), isNew: true)
            }
        } header: {
            HStack {
                Text(app.name)
                Spacer()
                Button("Edit") { editingApp = app }.font(.caption)
            }
        } footer: {
            if !app.note.isEmpty { Text(app.note) }
        }
    }

    private func line(_ l: MIDIMapLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(l.channel.map { "Ch \($0)" } ?? "–").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Text(l.message).font(.callout.monospacedDigit().weight(.semibold)).frame(minWidth: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.target)
                if !l.detail.isEmpty { Text(l.detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: StageCharts' own part (live)

    private var listenChannel: Int? { midi.mapping.listenChannel == 0 ? nil : midi.mapping.listenChannel }

    private var stageChartsReceives: [MIDIMapLine] {
        let m = midi.mapping
        var out: [MIDIMapLine] = []
        func message(_ t: MIDITrigger) -> String {
            switch t.kind {
            case .controlChange: return "CC \(t.number)"
            case .note: return "Note \(MIDITrigger.noteName(t.number))"
            case .programChange: return "Program \(t.number)"
            }
        }
        for action in StageAction.allCases {
            if let t = m.trigger(for: action) {
                out.append(.init(channel: t.channel ?? listenChannel, message: message(t), target: action.title))
            }
            if let x = m.extraBindings[action.rawValue] {
                out.append(.init(channel: x.channel ?? listenChannel, message: message(x), target: action.title,
                                 detail: "MC8 StageCharts bank"))
            }
        }
        if m.setSlotsEnabled {
            let last = min(127, m.setSlotFirstCC + m.setSlotCount - 1)
            out.append(.init(channel: listenChannel, message: "CC \(m.setSlotFirstCC)–\(last)",
                             target: "Open song 1–\(last - m.setSlotFirstCC + 1) of the set"))
        }
        let own = midi.songTriggers()
        if !own.isEmpty {
            out.append(.init(channel: listenChannel, message: "\(own.count) message\(own.count == 1 ? "" : "s")",
                             target: "Songs with their own MIDI message", detail: "Set per song in MIDI control"))
        }
        if m.programChangeSelectsSong {
            out.append(.init(channel: listenChannel, message: "Program 1–128", target: "Song by list position"))
        }
        return out
    }

    private var stageChartsSends: [MIDIMapLine] {
        let m = midi.mapping
        var out: [MIDIMapLine] = []
        if helixSnapshots {
            out.append(.init(channel: helixChannel, message: "CC 69", target: "Helix Native · Snapshot",
                             detail: "when a song opens (0 = snapshot 1)"))
        }
        if helixGuitarBlock {
            out.append(.init(channel: helixChannel, message: "CC 14–16", target: "Helix Native · Knobs 14–16",
                             detail: "guitar EQ level, low, high for the guitar you're playing"))
        }
        if m.sendSongChanges {
            let ch = max(1, m.listenChannel)
            switch m.sendKind {
            case .setSlotCC:
                out.append(.init(channel: ch, message: "CC \(m.setSlotFirstCC)+", target: "Song picked on this device",
                                 detail: "set position"))
            case .programChange:
                out.append(.init(channel: ch, message: "Program", target: "Song picked on this device"))
            }
        }
        if mc8Labels {
            out.append(.init(channel: nil, message: "SysEx", target: "Morningstar MC8 · switch labels",
                             detail: "per song, only on the \(MC8Link.shared.bankName) bank"))
        }
        for r in midi.routes where r.enabled {
            out.append(.init(channel: nil, message: "Route", target: "\(r.fromTitle) → \(r.toTitle)",
                             detail: "\(r.inChannelText) → \(r.outChannelText)"))
        }
        return out
    }

    // MARK: Saving

    private func update(_ change: (inout RigMIDIMap) -> Void) {
        var m = map
        change(&m)
        guard m != map else { return }
        map = m
        do {
            try m.save(to: library.base)
            library.onLocalChange?()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "CC 14" sorts before "CC 101": by kind, then first number.
    static func sortKey(_ message: String) -> String {
        let kind = message.prefix { !$0.isNumber }
        let n = Int(message.drop { !$0.isNumber }.prefix { $0.isNumber }) ?? 0
        return "\(kind)\(String(format: "%04d", n))"
    }
}

// MARK: - Editors

@available(iOS 16, macOS 13, *)
private struct RowEditor: View {
    let edit: MIDIMapPage.RowEdit
    let onSave: (RigMIDIMap.Row) -> Void
    let onDelete: () -> Void
    @State private var row: RigMIDIMap.Row
    @Environment(\.dismiss) private var dismiss

    init(edit: MIDIMapPage.RowEdit, onSave: @escaping (RigMIDIMap.Row) -> Void, onDelete: @escaping () -> Void) {
        self.edit = edit; self.onSave = onSave; self.onDelete = onDelete
        _row = State(initialValue: edit.row)
    }

    var body: some View {
        NavigationStack {
            Form {
                Stepper("Channel \(row.channel)", value: $row.channel, in: 1...16)
                TextField("Message (e.g. CC 14, CC 49–54, Note C3)", text: $row.message)
                TextField("What it controls (e.g. Helix Native · Knob 14)", text: $row.target)
                TextField("Note (optional)", text: $row.detail)
                if !edit.isNew {
                    Button("Delete mapping", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(edit.isNew ? "Add mapping" : "Edit mapping")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(row); dismiss() }
                        .disabled(row.message.trimmingCharacters(in: .whitespaces).isEmpty
                                  || row.target.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }
}

@available(iOS 16, macOS 13, *)
private struct AppEditor: View {
    let isNew: Bool
    let onSave: (RigMIDIMap.App) -> Void
    let onDelete: () -> Void
    @State private var app: RigMIDIMap.App
    @Environment(\.dismiss) private var dismiss

    init(app: RigMIDIMap.App, isNew: Bool, onSave: @escaping (RigMIDIMap.App) -> Void, onDelete: @escaping () -> Void) {
        self.isNew = isNew; self.onSave = onSave; self.onDelete = onDelete
        _app = State(initialValue: app)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Ableton Live, Playback, MC8)", text: $app.name)
                TextField("Note (optional)", text: $app.note, axis: .vertical)
                if !isNew {
                    Button("Delete \(app.name) and its \(app.rows.count) mappings", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Add a program or device" : "Edit \(app.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(app); dismiss() }
                        .disabled(app.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 220)
        #endif
    }
}
