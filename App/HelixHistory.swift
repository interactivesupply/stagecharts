import Foundation

/// The story of one generated Helix preset: every version, with the request that produced it, so the preset can be
/// refined over time ("less gain in the verse", "add a tremolo on Switch 4") instead of designed from scratch.
/// Saved next to the preset in the library's Helix folder ("Sunday Crunch.hlx" → "Sunday Crunch.history.json"),
/// so it syncs with the library.
struct HelixHistory: Codable {
    struct Revision: Codable, Identifiable {
        enum Kind: String, Codable { case design, change, imported, restored }
        var id = UUID()
        var date = Date()
        var kind: Kind
        /// The description (for a design), the change asked for, or what happened (import / restore).
        var request: String
        /// Claude's design (without the blocks StageCharts adds: volume pedal, guitar EQ).
        var design: HelixDesign
        var research: String? = nil
        var model: String? = nil
        var effort: String? = nil
        /// Per-song notes for the set, by set item id.
        var songNotes: [String: String]? = nil
        /// StageCharts settings it was built with ("Two DSPs · even levels · output +1.5 dB · 3 knobs · 6 switches").
        var settings: String? = nil
    }

    var version = 1
    /// The .hlx file name in the Helix folder.
    var file: String
    var revisions: [Revision] = []

    var current: Revision? { revisions.last }
    /// The original description (the latest full design's).
    var description: String { revisions.last(where: { $0.kind == .design })?.request ?? "" }
    /// What Claude should know when making the next change: each request in order.
    var requestLog: [String] {
        revisions.map { r in
            switch r.kind {
            case .design: return "Designed from: \(r.request)"
            case .change: return "Changed: \(r.request)"
            case .imported: return "The player edited it by hand in Helix Native (the current preset includes those edits)."
            case .restored: return r.request
            }
        }
    }

    static func url(for file: String, in folder: URL) -> URL {
        folder.appendingPathComponent((file as NSString).deletingPathExtension + ".history.json")
    }

    static func load(file: String, in folder: URL) -> HelixHistory? {
        guard let d = try? Data(contentsOf: url(for: file, in: folder)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(HelixHistory.self, from: d)
    }

    func save(in folder: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url(for: file, in: folder), options: .atomic)
    }

    /// Every preset in the folder that has a history, newest change first.
    static func all(in folder: URL) -> [HelixHistory] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".history.json") }
            .compactMap { f -> HelixHistory? in
                let name = String(f.dropLast(".history.json".count)) + ".hlx"
                return load(file: name, in: folder)
            }
            .sorted { ($0.current?.date ?? .distantPast) > ($1.current?.date ?? .distantPast) }
    }

    /// The .hlx was written after the last version was saved (e.g. exported over it from Helix Native).
    func changedOutside(in folder: URL) -> Bool {
        let path = folder.appendingPathComponent(file).path
        guard let saved = current?.date,
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return false }
        return modified.timeIntervalSince(saved) > 10
    }

    /// A one-line summary of the StageCharts settings a preset is built with.
    static func settingsLine(volumePedal: Bool, knobs: Int, switches: Int, guitarBlock: Bool) -> String {
        var parts = [HelixBuilder.twoDSP ? "two DSPs" : "one DSP"]
        if HelixBuilder.evenLevels { parts.append("even levels") }
        if HelixBuilder.outputLevel != 0 { parts.append(String(format: "output %+.1f dB", HelixBuilder.outputLevel)) }
        if volumePedal { parts.append("volume pedal") }
        if guitarBlock { parts.append("guitar EQ") }
        parts.append("\(knobs) knobs · \(switches) switches")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Reading a preset back

/// Turns a .hlx (one StageCharts made, possibly edited by hand in Helix Native) back into a design, so the next change
/// builds on the player's own edits instead of overwriting them.
enum HelixImport {
    struct Result { var design: HelixDesign; var notes: [String] }

    /// `previous` supplies what a .hlx doesn't hold: the songs' snapshots and each block's "why".
    /// The volume pedal and guitar EQ StageCharts adds are left out (it adds them again when building).
    static func design(from preset: JSON, catalog: HelixCatalog, previous: HelixDesign?) -> Result? {
        guard let data = preset["data"] as? JSON, let tone = data["tone"] as? JSON else { return nil }
        var notes: [String] = []
        let global = tone["global"] as? JSON ?? [:]

        // Blocks in signal order: DSP 1 then DSP 2; in each, before the split, path A, path B, after the merge.
        struct Found { var dsp: Int; var key: String; var block: JSON; var lane: String; var order: Int }
        var found: [Found] = []
        var paths: HelixDesign.Paths?
        var usedSplit = false
        for d in 0..<2 {
            guard let dsp = tone["dsp\(d)"] as? JSON else { continue }
            let split = (global["@topology\(d)"] as? String ?? "A") != "A"
            let splitAt = (dsp["split"] as? JSON)?["@position"] as? Int ?? 0
            let joinAt = (dsp["join"] as? JSON)?["@position"] as? Int ?? 8
            let keepSplit = split && !usedSplit
            if split && usedSplit { notes.append("Both DSPs had a split; the second one's paths are read as one chain.") }
            var any = false
            for (k, v) in dsp where k.hasPrefix("block") {
                guard let b = v as? JSON, let pos = b["@position"] as? Int else { continue }
                let path = b["@path"] as? Int ?? 0
                var lane = "series", order = pos * 2
                if keepSplit, pos >= splitAt, pos < joinAt {
                    lane = path == 1 ? "B" : "A"
                    order = 1000 + (path == 1 ? 500 : 0) + pos
                } else if keepSplit, pos >= joinAt {
                    order = 3000 + pos
                } else if path == 1 {
                    order = pos * 2 + 1
                }
                found.append(.init(dsp: d, key: k, block: b, lane: lane, order: d * 10000 + order))
                if lane != "series" { any = true }
            }
            if keepSplit, any {
                usedSplit = true
                if let j = dsp["join"] as? JSON {
                    func n(_ k: String, _ def: Double) -> Double { (j[k]).flatMap(HelixCatalog.number) ?? def }
                    paths = .init(levelA: n("A Level", 0), panA: n("A Pan", 0.5), levelB: n("B Level", 0),
                                  panB: n("B Pan", 0.5), invertB: j["B Polarity"] as? Bool ?? false)
                }
            }
        }
        found.sort { $0.order < $1.order }

        // Leave out what StageCharts adds itself: the guitar EQ and the volume pedal at the front of DSP 1.
        var skip = Set<String>()
        for f in found.prefix(2) where f.dsp == 0 {
            let m = f.block["@model"] as? String ?? ""
            if m == HelixBuilder.guitarModel || m.hasPrefix("HD2_VolPanVol") { skip.insert("dsp0.\(f.key)") } else { break }
        }
        found.removeAll { skip.contains("dsp\($0.dsp).\($0.key)") }

        var index: [String: Int] = [:]           // "dsp1.block2" → design block index
        var blocks: [HelixDesign.Block] = []
        for f in found {
            guard let id = f.block["@model"] as? String, let model = catalog.models[id] else {
                notes.append("Left out \(f.block["@model"] as? String ?? "a block"): it isn't in your Helix catalog."); continue
            }
            var settings: [HelixDesign.Setting] = []
            for (p, v) in f.block where !p.hasPrefix("@") {
                guard let ex = model.example[p] else { continue }
                let x: Double? = HelixCatalog.isBool(v) ? ((v as? Bool) == true ? 1 : 0) : HelixCatalog.number(v)
                guard let x else { continue }
                let e: Double? = HelixCatalog.isBool(ex) ? ((ex as? Bool) == true ? 1 : 0) : HelixCatalog.number(ex)
                if e == nil || abs(e! - x) > 1e-6 { settings.append(.init(param: p, value: x)) }
            }
            settings.sort { $0.param < $1.param }
            var cab: String?
            if let ref = f.block["@cab"] as? String, let c = (tone["dsp\(f.dsp)"] as? JSON)?[ref] as? JSON,
               let cm = c["@model"] as? String {
                let own = model.linked.values.first?["@model"] as? String
                if cm != own { cab = cm }
            }
            let why = previous?.blocks.first { $0.model == id }?.why
            index["dsp\(f.dsp).\(f.key)"] = blocks.count
            blocks.append(.init(model: id, settings: settings, why: why, cab: cab, lane: f.lane,
                                stereo: f.block["@stereo"] as? Bool))
        }
        guard !blocks.isEmpty else { return nil }

        // Snapshots: which blocks are on, and every snapshot-controlled value.
        var snapshots: [HelixDesign.Snapshot] = []
        for si in 0..<8 {
            guard let s = tone["snapshot\(si)"] as? JSON, s["@valid"] as? Bool == true else { continue }
            var enabled = Array(repeating: true, count: blocks.count)
            var settings: [HelixDesign.SnapshotSetting] = []
            for (key, bi) in index {
                let parts = key.split(separator: ".").map(String.init)
                if let on = ((s["blocks"] as? JSON)?[parts[0]] as? JSON)?[parts[1]] as? Bool { enabled[bi] = on }
                if let params = ((s["controllers"] as? JSON)?[parts[0]] as? JSON)?[parts[1]] as? JSON {
                    for (p, e) in params {
                        guard let v = (e as? JSON)?["@value"] else { continue }
                        let x: Double? = HelixCatalog.isBool(v) ? ((v as? Bool) == true ? 1 : 0) : HelixCatalog.number(v)
                        if let x { settings.append(.init(block: bi, param: p, value: x)) }
                    }
                }
            }
            settings.sort { ($0.block, $0.param) < ($1.block, $1.param) }
            snapshots.append(.init(name: s["@name"] as? String ?? "Snapshot \(si + 1)", tempo: (s["@tempo"]).flatMap(HelixCatalog.number),
                                   enabled: enabled, settings: settings))
        }
        if snapshots.isEmpty {
            snapshots = [.init(name: "Snapshot 1", tempo: nil, enabled: blocks.map { _ in true }, settings: [])]
        }

        // Live controls (StageCharts re-adds the volume pedal and guitar knobs itself).
        var controls: [HelixDesign.Control] = []
        let slots = (tone["automation"] as? JSON)?["@assignments"] as? [Any] ?? []
        for (slot, a) in slots.enumerated() {
            guard let a = a as? JSON, let param = a["@param"] as? String else { continue }
            let parts = param.split(separator: ".").map(String.init)
            guard parts.count == 3, let bi = index["\(parts[0]).\(parts[1])"] else { continue }
            if slot >= 16 {
                controls.append(.init(kind: "switch", number: slot - 15, block: bi, param: "", min: 0, max: 1))
            } else {
                controls.append(.init(kind: "knob", number: slot + 1, block: bi, param: parts[2],
                                      min: (a["@min"]).flatMap(HelixCatalog.number) ?? 0,
                                      max: (a["@max"]).flatMap(HelixCatalog.number) ?? 1))
            }
        }

        let meta = data["meta"] as? JSON ?? [:]
        let design = HelixDesign(name: meta["name"] as? String ?? previous?.name ?? "Imported",
                                 blocks: blocks, snapshots: snapshots,
                                 songs: (previous?.songs ?? []).filter { $0.snapshot < snapshots.count },
                                 summary: previous?.summary ?? "", paths: paths, controls: controls)
        return Result(design: design, notes: notes)
    }
}
