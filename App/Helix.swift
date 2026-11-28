import Foundation

// Line 6 Helix Native presets (.hlx) made by Claude from a description.
//
// An .hlx file is JSON ("L6Preset"). Line 6 doesn't publish the format, so StageCharts learns it from the
// user's own exported presets: every amp/effect model they contain, with its full set of parameters, plus
// one Helix Native preset as the skeleton (inputs, outputs, global settings). Claude only picks models
// and values from that catalog; StageCharts assembles the file. The catalog stays in the user's library
// (never in the app's repository).
//
// Snapshots: one preset per set, one snapshot per song (up to 8). Snapshot-controlled values use
// controller 19; StageCharts recalls a snapshot with MIDI CC 69 (value 0 = snapshot 1).

typealias JSON = [String: Any]

enum HelixError: LocalizedError {
    case noPresets, noNativePreset, noCatalog, bad(String)
    var errorDescription: String? {
        switch self {
        case .noPresets: return "No Helix presets (.hlx or .hls) were found in that folder."
        case .noNativePreset: return "None of those presets came from Helix Native. Export at least one preset from Helix Native into the folder."
        case .noCatalog: return "Choose your Helix presets folder in Settings → Helix first."
        case .bad(let m): return m
        }
    }
}

// MARK: - Catalog

/// What StageCharts knows about the user's Helix: models with example settings, and a preset skeleton.
struct HelixCatalog {
    struct Model {
        let id: String
        let type: Int
        /// A real block using this model (all parameters), and any entries it references (e.g. "@cab": "cab0").
        let example: JSON
        let linked: [String: JSON]
        /// Lowest and highest value seen for each number parameter.
        let ranges: [String: (Double, Double)]
        var category: String { HelixCatalog.category(id, type: type) }
    }

    /// A setting's real limits, from Helix Native's own model definitions (res/*.models).
    struct Limit {
        let lo: Double, hi: Double
        /// Some settings have a smaller maximum when the block is stereo (e.g. Simple Delay Time 8 s mono, 4 s stereo).
        let hiStereo: Double?
        func clamp(_ x: Double, stereo: Bool) -> Double { min(max(x, lo), stereo ? (hiStereo ?? hi) : hi) }
    }

    var models: [String: Model] = [:]
    /// Model id → setting → limits. Empty when Helix Native's definitions weren't found.
    var limits: [String: [String: Limit]] = [:]
    /// Model id → Line 6's own name ("Bucket Brigade").
    var names: [String: String] = [:]
    /// Model id → [can run mono, can run stereo], from Helix Native's definitions.
    var channels: [String: [Bool]] = [:]
    /// Model id → setting → expression pedal assignment from the player's presets (e.g. volume "Pedal" on EXP 2).
    var pedals: [String: [String: JSON]] = [:]
    /// Model id → what it is: the gear Line 6 based it on and a short description. From "model-info.json" in the
    /// Helix folder (kept in the player's library, not the app), read fresh with the catalog.
    var info: [String: Info] = [:]
    var skeleton: JSON = [:]
    var presetCount = 0

    struct Info {
        let basedOn: String?
        let about: String?
    }

    static func infoURL(in folder: URL) -> URL { folder.appendingPathComponent("model-info.json") }

    /// {"HD2_DistTeemah": {"basedOn": "Paul Cochrane Timmy Overdrive", "about": "..."}, ...}
    static func readInfo(in folder: URL) -> [String: Info] {
        guard let d = try? Data(contentsOf: infoURL(in: folder)),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: String]] else { return [:] }
        return j.mapValues { Info(basedOn: $0["basedOn"], about: $0["about"]) }
    }

    /// "Teemah! (based on Paul Cochrane Timmy Overdrive)" for showing a block to the player.
    static func describe(_ id: String) -> String {
        let name = displayName(id)
        guard let b = shared?.info[id]?.basedOn, !b.localizedCaseInsensitiveContains("Line 6 original") else { return name }
        return "\(name) (based on \(b))"
    }
    var scanned = Date()

    static func url(in folder: URL) -> URL { folder.appendingPathComponent("catalog.json") }

    // Models that need things StageCharts can't set up (user IR files, loops, hardware sends and inputs).
    static func usable(_ id: String) -> Bool {
        !["Impulse", "Looper", "FXLoop", "Send", "Return", "Variax", "Input", "Output", "AppDSP"]
            .contains { id.localizedCaseInsensitiveContains($0) }
    }

    static func category(_ id: String, type: Int) -> String {
        let n = id.replacingOccurrences(of: "HD2_", with: "")
        let table: [(String, String)] = [
            ("Preamp", "preamp (needs a cab after it)"), ("VolPan", "volume / pan"), ("Wah", "wah (on a pedal)"), ("Cab", "cab"), ("Dist", "drive / boost / fuzz"),
            ("Delay", "delay"), ("DL4", "delay"), ("Reverb", "reverb"), ("Chorus", "modulation"), ("Flanger", "modulation"),
            ("Phaser", "modulation"), ("Tremolo", "modulation"), ("Rotary", "modulation"), ("Vibrato", "modulation"),
            ("Mod", "modulation"), ("Compressor", "compressor"), ("Comp", "compressor"), ("EQ", "EQ"), ("Gate", "noise gate"),
            ("Pitch", "pitch / synth"), ("Poly", "pitch / synth"), ("Synth", "pitch / synth"), ("Filter", "filter"),
            ("MM4", "modulation"),
        ]
        if n.hasPrefix("Amp") { return type == 3 ? "amp with its own cab" : "amp (needs a cab after it)" }
        return table.first { n.hasPrefix($0.0) || n.contains($0.0) }?.1 ?? "effect"
    }

    /// "HD2_AmpPlacaterDirty" → "Placater Dirty".
    static func displayName(_ id: String) -> String {
        if let n = shared?.names[id] { return n }
        var n = id.replacingOccurrences(of: "HD2_", with: "").replacingOccurrences(of: "L6SPB_", with: "")
        for p in ["Amp", "Cab", "Dist", "Delay", "Reverb", "Compressor", "EQ", "Chorus", "Flanger", "Phaser", "Tremolo", "Pitch", "Filter", "Gate"]
            where n.hasPrefix(p) && n.count > p.count { n = String(n.dropFirst(p.count)); break }
        var out = ""
        for (i, c) in n.enumerated() {
            if i > 0, c.isUppercase, let prev = out.last, prev.isLowercase || prev.isNumber { out.append(" ") }
            out.append(c)
        }
        return out.replacingOccurrences(of: "_", with: " ")
    }

    /// The catalog last loaded or scanned (for display names).
    nonisolated(unsafe) static var shared: HelixCatalog?

    // MARK: Scanning

    /// Where Helix Native keeps its model definitions on a Mac.
    static let nativeResources = URL(fileURLWithPath: "/Library/Application Support/Line 6/Helix Native/res", isDirectory: true)

    /// Reads every .hlx / .hls under `folder`, plus Helix Native's model definitions (*.models) — from the folder
    /// if they were copied there, otherwise from Helix Native's own install on this Mac.
    static func scan(_ folder: URL) throws -> HelixCatalog {
        var presets: [JSON] = []
        var definitions: [URL] = []
        let fm = FileManager.default
        let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let u = e?.nextObject() as? URL {
            switch u.pathExtension.lowercased() {
            case "hlx":
                if let d = try? Data(contentsOf: u), let j = try? JSONSerialization.jsonObject(with: d) as? JSON { presets.append(j) }
            case "hls":
                if let d = try? Data(contentsOf: u) { presets += setlistPresets(d) }
            case "models":
                definitions.append(u)
            default: break
            }
        }
        guard !presets.isEmpty else { throw HelixError.noPresets }
        var cat = try build(from: presets)
        if definitions.isEmpty {
            definitions = (try? fm.contentsOfDirectory(at: nativeResources, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "models" } ?? []
        }
        cat.readDefinitions(definitions)
        shared = cat
        return cat
    }

    /// Helix Native's *.models files: a JSON array of {symbolicID, name, params: [{symbolicID, valueType, min, max,
    /// max_stereo?, default}], cablink/ircablink (amps), mono/stereo (effects)}. Gives every setting's real limits, and
    /// lets StageCharts use models that none of the player's presets contain, built from Line 6's default settings.
    mutating func readDefinitions(_ files: [URL]) {
        var defs: [String: (file: String, model: JSON)] = [:]
        for u in files {
            guard let d = try? Data(contentsOf: u), let list = try? JSONSerialization.jsonObject(with: d) as? [JSON] else { continue }
            let file = u.deletingPathExtension().lastPathComponent
            for m in list {
                guard let id = m["symbolicID"] as? String else { continue }
                defs[id] = (file, m)
                if let n = m["name"] as? String { names[id] = n }
                if m["mono"] != nil || m["stereo"] != nil {
                    channels[id] = [(m["mono"] as? Bool) ?? true, (m["stereo"] as? Bool) ?? true]
                }
                var l: [String: Limit] = [:]
                for p in m["params"] as? [JSON] ?? [] {
                    guard let k = p["symbolicID"] as? String, !k.hasPrefix("@"), (p["valueType"] as? Int) != 2,
                          let lo = p["min"].flatMap(Self.number), let hi = p["max"].flatMap(Self.number) else { continue }
                    l[k] = Limit(lo: lo, hi: hi, hiStereo: p["max_stereo"].flatMap(Self.number))
                }
                if !l.isEmpty { limits[id] = l }
            }
        }
        // Models the presets don't contain, from Line 6's defaults: amps (with their matching cab), preamps, single
        // cabs (type 2) and every kind of effect. Send/returns, I/O and the older cab and dual-cab formats are left out.
        let kinds: [String: Int] = ["amp": 3, "preamp": 1, "cabmicirs": 2, "delay": 7, "reverb": 7, "distortion": 0,
                                    "compressor": 0, "modulation": 0, "eq": 0, "filter": 0, "pitch-synth": 0, "gate": 0,
                                    "wah": 0, "volumepan": 0]
        let data = skeleton["data"] as? JSON
        let device = data?["device"] as? Int ?? 2162944
        let version = data?["device_version"] as? Int ?? 0
        // A model newer than the player's Helix Native (per its "devices" list) is left out.
        func supported(_ m: JSON) -> Bool {
            guard let list = m["devices"] as? [JSON],
                  let need = list.first(where: { ($0["id"] as? Int) == device })?["version"] as? String else { return true }
            return Int(need.replacingOccurrences(of: "0x", with: ""), radix: 16).map { $0 <= version } ?? true
        }
        for (id, def) in defs where models[id] == nil && Self.usable(id) && supported(def.model) {
            guard let type = kinds[def.file] else { continue }
            var block = Self.defaults(def.model)
            block["@model"] = id
            block["@type"] = type
            block["@enabled"] = true
            block["@no_snapshot_bypass"] = false
            block["@path"] = 0
            block["@position"] = 0
            var linked: [String: JSON] = [:]
            if def.file == "amp" {
                guard let cabID = def.model["ircablink"] as? String, let cab = defs[cabID], supported(cab.model) else { continue }
                var c = Self.defaults(cab.model)
                c["@model"] = cabID
                c["@enabled"] = true
                linked["cab0"] = c
                block["@cab"] = "cab0"
                block["@bypassvolume"] = block["@bypassvolume"] ?? 1.0
                block["@stereo"] = nil
            } else if type == 1 {
                block["@bypassvolume"] = block["@bypassvolume"] ?? 1.0
                block["@stereo"] = nil
            } else if type == 2 {
                block["@stereo"] = nil
            } else {
                // Stereo-only models must be placed as stereo.
                block["@stereo"] = (def.model["mono"] as? Bool) == false
                if type == 7 { block["@trails"] = false }
            }
            models[id] = Model(id: id, type: type, example: block, linked: linked, ranges: [:])
        }
    }

    /// A model definition's default settings, typed the way Helix writes them (on/off, whole number or decimal).
    /// Includes "@bypassvolume" for amps; other "@" settings are set by the caller.
    private static func defaults(_ model: JSON) -> JSON {
        var out: JSON = [:]
        for p in model["params"] as? [JSON] ?? [] {
            // Stereo-only settings are kept too: Helix writes them in mono blocks as well.
            guard let k = p["symbolicID"] as? String, let v = p["default"], k == "@bypassvolume" || !k.hasPrefix("@") else { continue }
            switch p["valueType"] as? Int {
            case 2: out[k] = (v as? Bool) ?? ((number(v) ?? 0) != 0)
            case 0: out[k] = Int((number(v) ?? 0).rounded())
            default: out[k] = number(v) ?? 0
            }
        }
        return out
    }

    /// A Helix setlist (.hls): {"encoded_data": base64(zlib(JSON)), …} holding {"presets": […]}.
    static func setlistPresets(_ data: Data) -> [JSON] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let enc = j["encoded_data"] as? String, var z = Data(base64Encoded: enc) else { return [] }
        if z.count > 2, z[z.startIndex] == 0x78 { z = z.dropFirst(2) }        // zlib header → raw deflate
        guard let raw = try? (z as NSData).decompressed(using: .zlib) as Data,
              let inner = try? JSONSerialization.jsonObject(with: raw) as? JSON else { return [] }
        return (inner["presets"] as? [JSON]) ?? []
    }

    static func build(from presets: [JSON]) throws -> HelixCatalog {
        var cat = HelixCatalog()
        var ranges: [String: [String: (Double, Double)]] = [:]
        for p in presets {
            let data = (p["data"] as? JSON) ?? p
            guard let tone = data["tone"] as? JSON else { continue }
            cat.presetCount += 1
            if cat.skeleton.isEmpty, (data["device"] as? Int) == 2162944 { cat.skeleton = skeleton(from: p) }
            for dsp in ["dsp0", "dsp1"] {
                guard let blocks = tone[dsp] as? JSON else { continue }
                for (key, value) in blocks where key.hasPrefix("block") {
                    guard let b = value as? JSON, let id = b["@model"] as? String, usable(id) else { continue }
                    for (k, v) in b where !k.hasPrefix("@") {
                        guard let x = number(v) else { continue }
                        let r = ranges[id]?[k] ?? (x, x)
                        ranges[id, default: [:]][k] = (min(r.0, x), max(r.1, x))
                    }
                    if cat.models[id] == nil {
                        var linked: [String: JSON] = [:]
                        if let ref = b["@cab"] as? String, let cab = blocks[ref] as? JSON { linked[ref] = cab }
                        cat.models[id] = Model(id: id, type: b["@type"] as? Int ?? 0, example: b, linked: linked, ranges: [:])
                    }
                }
            }
        }
        // Pedal assignments in the player's Helix Native presets (hardware Helix presets use EXP inputs Native doesn't have).
        for p in presets {
            let data = (p["data"] as? JSON) ?? p
            guard (data["device"] as? Int) == 2162944 else { continue }
            let tone = (data["tone"] as? JSON) ?? [:]
            for (dsp, v) in tone["controller"] as? JSON ?? [:] {
                for (key, params) in v as? JSON ?? [:] {
                    guard let id = ((tone[dsp] as? JSON)?[key] as? JSON)?["@model"] as? String else { continue }
                    for (param, c) in params as? JSON ?? [:] {
                        // Only MIDI CC (18): Helix Native has no EXP inputs, so EXP 1–3 entries do nothing there.
                        guard let c = c as? JSON, (c["@controller"] as? Int) == 18, cat.pedals[id]?[param] == nil else { continue }
                        cat.pedals[id, default: [:]][param] = c.filter { ["@controller", "@cc", "@min", "@max"].contains($0.key) }
                    }
                }
            }
        }
        guard !cat.models.isEmpty else { throw HelixError.noPresets }
        guard !cat.skeleton.isEmpty else { throw HelixError.noNativePreset }
        for (id, m) in cat.models {
            cat.models[id] = Model(id: id, type: m.type, example: m.example, linked: m.linked, ranges: ranges[id] ?? [:])
        }
        cat.scanned = Date()
        return cat
    }

    /// A Helix Native preset with its blocks, snapshots and controller/footswitch assignments removed.
    private static func skeleton(from p: JSON) -> JSON {
        var p = p
        var data = (p["data"] as? JSON) ?? [:]
        var tone = (data["tone"] as? JSON) ?? [:]
        for dsp in ["dsp0", "dsp1"] {
            if let blocks = tone[dsp] as? JSON {
                tone[dsp] = blocks.filter { k, _ in !k.hasPrefix("block") && !k.hasPrefix("cab") }
            }
        }
        for k in tone.keys where k.hasPrefix("snapshot") || ["controller", "footswitch", "automation"].contains(k) { tone[k] = nil }
        data["tone"] = tone
        p["data"] = data
        return p
    }

    static func number(_ v: Any) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
    static func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    static func isInteger(_ v: Any) -> Bool {
        guard let n = v as? NSNumber, !isBool(n) else { return false }
        return !CFNumberIsFloatType(n)
    }

    // MARK: Saving

    func save(in folder: URL) throws {
        var models: JSON = [:]
        for (id, m) in self.models {
            models[id] = ["type": m.type, "example": m.example, "linked": m.linked,
                          "ranges": m.ranges.mapValues { [$0.0, $0.1] }]
        }
        let lim = limits.mapValues { $0.mapValues { l -> [Double] in [l.lo, l.hi] + (l.hiStereo.map { [$0] } ?? []) } }
        let j: JSON = ["models": models, "skeleton": skeleton, "presetCount": presetCount,
                       "scanned": scanned.timeIntervalSince1970, "limits": lim, "names": names, "pedals": pedals, "channels": channels]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: j).write(to: Self.url(in: folder), options: .atomic)
    }

    static func load(from folder: URL) -> HelixCatalog? {
        guard let d = try? Data(contentsOf: url(in: folder)), let j = try? JSONSerialization.jsonObject(with: d) as? JSON,
              let models = j["models"] as? JSON, let skeleton = j["skeleton"] as? JSON else { return nil }
        var cat = HelixCatalog()
        cat.skeleton = skeleton
        cat.presetCount = j["presetCount"] as? Int ?? 0
        cat.scanned = Date(timeIntervalSince1970: j["scanned"] as? Double ?? 0)
        cat.names = j["names"] as? [String: String] ?? [:]
        cat.pedals = j["pedals"] as? [String: [String: JSON]] ?? [:]
        cat.channels = j["channels"] as? [String: [Bool]] ?? [:]
        cat.info = readInfo(in: folder)
        for (id, v) in j["limits"] as? [String: [String: [Double]]] ?? [:] {
            cat.limits[id] = v.compactMapValues { a in
                a.count >= 2 ? Limit(lo: a[0], hi: a[1], hiStereo: a.count > 2 ? a[2] : nil) : nil
            }
        }
        for (id, v) in models {
            guard let m = v as? JSON, let ex = m["example"] as? JSON else { continue }
            let r = (m["ranges"] as? [String: [Double]] ?? [:]).compactMapValues { $0.count == 2 ? ($0[0], $0[1]) : nil }
            cat.models[id] = Model(id: id, type: m["type"] as? Int ?? 0, example: ex,
                                   linked: m["linked"] as? [String: JSON] ?? [:], ranges: r)
        }
        shared = cat
        return cat
    }

    /// The expression pedal a block's settings follow: what the player's presets use for this model, else for the
    /// same kind of model. Helix Native's own Knob/Switch automation assignments aren't saved in preset files, so
    /// usually there's nothing to copy and the player assigns the pedal in Helix Native.
    /// Only wahs and volume pedals: other pedal assignments in the player's presets (e.g. a reverb mix on a pedal)
    /// belong to those presets, not to every new one.
    func pedalAssignments(for id: String) -> [String: JSON] {
        guard let m = models[id] else { return [:] }
        let isVolume = id.hasPrefix("HD2_VolPanVol")
        guard isVolume || m.category.hasPrefix("wah") else { return [:] }
        if let p = pedals[id] { return p }
        let kind = isVolume ? "volume" : m.category
        if let similar = pedals.first(where: { k, _ in
            k.hasPrefix("HD2_VolPanVol") == isVolume && (isVolume || models[k]?.category == kind) })?.value,
           similar.keys.allSatisfy({ m.example[$0] != nil }) {
            return similar
        }
        return [:]
    }

    /// A cab model as the cab inside an amp block (amp + cab): its settings, model and on/off only.
    func linkedCab(_ id: String) -> JSON? {
        guard let m = models[id], m.type == 2 else { return nil }
        return m.example.filter { k, _ in !k.hasPrefix("@") || k == "@model" || k == "@enabled" }
    }

    // MARK: For Claude

    /// One line per model: id, kind, and each setting with its example value and the range seen.
    var promptText: String {
        models.values.sorted { ($0.category, $0.id) < ($1.category, $1.id) }.map { m in
            let params = m.example.keys.filter { !$0.hasPrefix("@") }.sorted().map { k -> String in
                let v = m.example[k]!
                if Self.isBool(v) { return "\(k)=\((v as? Bool) == true ? 1 : 0) (on/off)" }
                guard let x = Self.number(v) else { return "\(k)" }
                let r: String
                if let l = limits[m.id]?[k] {          // Helix Native's real limits
                    r = " [\(Self.short(l.lo))…\(Self.short(l.hi))\(l.hiStereo.map { ", stereo max \(Self.short($0))" } ?? "")]"
                } else {
                    r = m.ranges[k].map { $0.0 == $0.1 ? "" : " [seen \(Self.short($0.0))…\(Self.short($0.1))]" } ?? ""
                }
                return "\(k)=\(Self.short(x))\(r)\(Self.isInteger(v) ? " int" : "")"
            }
            let name = names[m.id].map { " (\($0))" } ?? ""
            var kind = m.category
            if m.example["@stereo"] != nil {
                switch channels[m.id] {
                case [true, false]?: kind += ", mono only"
                case [false, true]?: kind += ", stereo only"
                default: kind += ", mono or stereo"
                }
            }
            var what = ""
            if let i = info[m.id] {
                if let b = i.basedOn, !b.isEmpty { what += " Based on \(b)." }
                if let a = i.about, !a.isEmpty { what += " \(a)" }
            }
            return "\(m.id)\(name) — \(kind).\(what) Settings: " + params.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    static func short(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e6 ? String(Int(x)) : String(format: "%.3g", x)
    }
}

extension SongLibrary {
    /// Generated presets and the catalog: the library's "Helix" folder (synced with Google Drive).
    var helixFolder: URL { base.appendingPathComponent("Helix", isDirectory: true) }

    /// Snapshot names of the set's preset: saved with the set, else read from the preset file
    /// (sets saved before names were stored). Empty when the set has no preset.
    /// What the set's Helix preset put on automation Switches 1–6 (block names; "" = unassigned), for MC8 labels.
    func helixSwitchNames(_ set: SetList) -> [String] {
        guard let file = set.helixPreset,
              let data = try? Data(contentsOf: helixFolder.appendingPathComponent(file)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tone = (root["data"] as? [String: Any])?["tone"] as? [String: Any],
              let slots = (tone["automation"] as? [String: Any])?["@assignments"] as? [Any] else { return [] }
        return (16..<22).map { slot in
            guard slot < slots.count, let a = slots[slot] as? [String: Any], let param = a["@param"] as? String else { return "" }
            let parts = param.split(separator: ".").map(String.init)        // dsp1.block3.@enabled
            guard parts.count >= 2, let dsp = tone[parts[0]] as? [String: Any],
                  let model = (dsp[parts[1]] as? [String: Any])?["@model"] as? String else { return "" }
            return HelixCatalog.displayName(model)
        }
    }

    func helixSnapshotNames(_ set: SetList) -> [String] {
        if let names = set.helixSnapshotNames { return names }
        guard let file = set.helixPreset,
              let data = try? Data(contentsOf: helixFolder.appendingPathComponent(file)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tone = (root["data"] as? [String: Any])?["tone"] as? [String: Any] else { return [] }
        var names: [String] = []
        for i in 0..<8 {
            guard let snap = tone["snapshot\(i)"] as? [String: Any], snap["@valid"] as? Bool == true,
                  let name = snap["@name"] as? String else { break }
            names.append(name)
        }
        return names
    }
}

// MARK: - Claude's design

/// What Claude returns: the chain, the snapshots, and which song uses which snapshot.
struct HelixDesign: Codable {
    struct Setting: Codable { var param: String; var value: Double }
    struct Block: Codable {
        var model: String
        var settings: [Setting]
        var why: String?
        /// For an amp with its own cab: a different cab model to use in place of its matching one.
        var cab: String? = nil
        /// "series", or "A" / "B" for the two parallel paths between a split and its merge.
        var lane: String? = nil
        /// true = stereo, false = mono, nil = the model's usual.
        var stereo: Bool? = nil
    }
    /// How the two parallel paths are merged: levels in dB, pans 0 (left)…1 (right), B's polarity flipped.
    struct Paths: Codable { var levelA: Double; var panA: Double; var levelB: Double; var panB: Double; var invertB: Bool }
    struct SnapshotSetting: Codable { var block: Int; var param: String; var value: Double }
    struct Snapshot: Codable {
        var name: String
        var tempo: Double?
        var enabled: [Bool]
        var settings: [SnapshotSetting]
    }
    struct SongSnapshot: Codable { var song: Int; var snapshot: Int }

    var name: String
    var blocks: [Block]
    var snapshots: [Snapshot]
    var songs: [SongSnapshot]
    var summary: String
    var paths: Paths? = nil
    /// Helix Native's automation Knobs and Switches, which the player's MIDI controller drives.
    struct Control: Codable {
        var kind: String          // "knob" or "switch"
        var number: Int           // Knob 1… / Switch 1…
        var block: Int
        var param: String         // a knob's setting; "" for a switch (on/off)
        var min: Double
        var max: Double
    }
    var controls: [Control]? = nil
}

extension HelixDesign {
    /// The design with `model` as its first block, on in every snapshot. With `replacing`, any other block of that
    /// model is removed (the player's volume pedal replaces one Claude added anyway).
    func withBlockFirst(_ model: String, why: String = "Your volume pedal", settings: [Setting] = [],
                        stereo: Bool? = nil, replacing: Bool = true) -> HelixDesign {
        var d = self
        let keep = blocks.indices.filter { !replacing || blocks[$0].model != model }
        var newIndex: [Int: Int] = [:]
        for (n, old) in keep.enumerated() { newIndex[old] = n + 1 }
        d.blocks = [Block(model: model, settings: settings, why: why, lane: "series", stereo: stereo)] + keep.map { blocks[$0] }
        d.snapshots = snapshots.map { s in
            var s = s
            s.enabled = [true] + keep.map { s.enabled.indices.contains($0) ? s.enabled[$0] : true }
            s.settings = s.settings.compactMap { st in
                guard let n = newIndex[st.block] else { return nil }
                var st = st; st.block = n; return st
            }
            return s
        }
        d.controls = controls?.compactMap { c in
            guard let n = newIndex[c.block] else { return nil }
            var c = c; c.block = n; return c
        }
        return d
    }
}

struct HelixSong {
    let title: String
    let artist: String?
    let key: String?
    let bpm: Int?
    let time: String?
    var note: String
}

enum HelixDesigner {
    /// A change to an existing preset: the current design, what's been asked so far, and the new request.
    struct Revision { var current: HelixDesign; var history: [String]; var change: String }

    static let system = """
    You design guitar presets for Line 6 Helix Native for a worship guitarist. You get a description of the \
    tones wanted, optionally the songs in a set list (with key, BPM and notes), and a catalog of the models \
    this player's Helix Native has, each with its settings, an example value and the range seen in their presets. \
    Most models also say what real gear Line 6 based them on and describe the sound: choose models by that (e.g. a \
    Klon-style drive, a Vox-style amp), and when the request names real gear, use the model based on it. \
    There may also be tone research on the recordings: recreate the documented rigs from the catalog's closest \
    models (by what they're based on), and say in a block's `why` which recording or part it recreates.

    Rules:
    - Use only model ids from the catalog, and only setting names listed for that model. Values are in the \
    same units as the examples (most knobs are 0–1; levels in dB; delay Time in seconds; frequencies in Hz). \
    On/off settings are 1 or 0. Settings marked int must be whole numbers. \
    A range in [lo…hi] is the setting's allowed range: never go outside it ("seen" ranges are only what the player has used). \
    Delay Time ranges differ a lot between models (some analog delays stop at 0.3 s): pick a delay whose Time range covers \
    every song's delay time.
    - Blocks are listed in signal order (e.g. gate/comp → drives → amp → cab → modulation → delay → reverb). Each block's \
    `lane` is "series" for the main chain. For parallel sounds (two amps, a wet/dry rig, a pitch or reverb blended in \
    beside the dry signal) give consecutive blocks lane "A" or "B": the signal splits before the first of them and \
    merges after the last, and series blocks after them come after the merge. Use at most one split. Set `paths` \
    (merge levels in dB, usually 0; pans 0 = left, 0.5 = centre, 1 = right; invertB false) when there is a "B" \
    block, otherwise null. How many positions the chain has is in the request (a split counts its longer path).
    - `stereo`: for a model marked "mono or stereo", true or false to choose, null for its usual. Amps and cabs are \
    mono. Stereo effects after the merge keep a panned A/B spread; a mono block there collapses it to the centre.
    An amp or preamp marked "needs a cab after it" must be followed by a cab block. An "amp with its own cab" comes with \
    its matching cab; to pair it with a different cab instead, set the block's `cab` to that cab's model id (a "cab" from \
    the catalog) — this uses no extra block. Otherwise `cab` is null. Mixing a preamp or amp with a cab it isn't \
    usually paired with is fine when it suits the tone.
    - Live controls (`controls`): the player's MIDI controller drives Helix Native's automation Knobs and Switches \
    (how many is in the request). Give each switch to a block worth turning on or off by foot during a song (a boost, \
    a delay, a reverb, a modulation): kind "switch", param "", min 0, max 1. Give knobs to settings worth riding live \
    (drive gain, a delay or reverb mix, a wah's Pedal): kind "knob", with the setting and the range the knob sweeps \
    (inside its allowed range). A wah needs a knob on its Pedal. Never put a knob on a setting that snapshots change. \
    Use each knob or switch number once; leave them out when nothing is worth controlling. `block` is the block's index.
    - The request may say StageCharts adds blocks of its own first (the player's volume pedal, a guitar EQ). Don't \
    add those yourself, use at most the positions the request leaves you, and count block indices from your own \
    blocks (the added ones aren't among them).
    - The player may switch between several guitars (listed in the request). A guitar EQ added first matches each \
    guitar's level and tone before the amp, so voice the preset for a typical guitar between them: set amp and \
    drive gain so it still has headroom with hot humbuckers and enough grit with single coils, and avoid extremes \
    of brightness or bass that only suit one guitar.
    - Snapshots (1–8) switch blocks on/off and change settings between songs or parts. `enabled` has one entry per block. \
    `settings` are only the values that differ from the block's own settings in that snapshot. Names at most 10 characters.
    - Delays: for timed delays set TempoSync1 (and TempoSync2 if present) to 0 and set Time (seconds) from the song's BPM: \
    quarter = 60/BPM, dotted eighth = 0.75 × 60/BPM, eighth = 30/BPM. When songs have different BPMs, give each snapshot its own Time.
    - Set each snapshot's tempo to its song's BPM when known.
    - With a set list: map every song (by index) to a snapshot; songs with the same feel can share one. Without songs, `songs` is empty.
    - Preset name at most 16 characters. `summary`: two or three sentences on the sound and how the snapshots differ.
    - Keep levels sensible: drives and boosts shouldn't add more than ~+6 dB. The request says who sets amp channel volumes.
    """

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["name", "blocks", "snapshots", "songs", "summary", "paths", "controls"],
        "properties": [
            "controls": ["type": "array", "items": [
                "type": "object", "additionalProperties": false,
                "required": ["kind", "number", "block", "param", "min", "max"],
                "properties": ["kind": ["type": "string", "enum": ["knob", "switch"]], "number": ["type": "integer"],
                               "block": ["type": "integer"], "param": ["type": "string"],
                               "min": ["type": "number"], "max": ["type": "number"]],
            ]],
            "name": ["type": "string"],
            "paths": ["type": ["object", "null"], "additionalProperties": false,
                      "required": ["levelA", "panA", "levelB", "panB", "invertB"],
                      "properties": ["levelA": ["type": "number"], "panA": ["type": "number"], "levelB": ["type": "number"],
                                     "panB": ["type": "number"], "invertB": ["type": "boolean"]]],
            "summary": ["type": "string"],
            "blocks": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["model", "settings", "why", "cab", "lane", "stereo"],
                "properties": [
                    "model": ["type": "string"],
                    "lane": ["type": "string", "enum": ["series", "A", "B"]],
                    "stereo": ["type": ["boolean", "null"]],
                    "why": ["type": "string"],
                    "cab": ["type": ["string", "null"]],
                    "settings": ["type": "array", "items": [
                        "type": "object", "additionalProperties": false, "required": ["param", "value"],
                        "properties": ["param": ["type": "string"], "value": ["type": "number"]],
                    ]],
                ],
            ]],
            "snapshots": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["name", "tempo", "enabled", "settings"],
                "properties": [
                    "name": ["type": "string"],
                    "tempo": ["type": ["number", "null"]],
                    "enabled": ["type": "array", "items": ["type": "boolean"]],
                    "settings": ["type": "array", "items": [
                        "type": "object", "additionalProperties": false, "required": ["block", "param", "value"],
                        "properties": ["block": ["type": "integer"], "param": ["type": "string"], "value": ["type": "number"]],
                    ]],
                ],
            ]],
            "songs": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["song", "snapshot"],
                "properties": ["song": ["type": "integer"], "snapshot": ["type": "integer"]],
            ]],
        ],
    ]

    static let researchSystem = """
    You research the electric guitar tones on worship recordings so a Helix preset can recreate them. You get a \
    player's description of the tones they want and, optionally, the songs in their set (title, songwriter, key, BPM). \
    The names given are songwriters, not necessarily the recording artist: work out the best-known recording, or the \
    one the description names.

    Search the web for rig rundowns, tone tutorials, worship-guitar patch breakdowns, gear interviews and the \
    original multitrack/guitar-stem guides for those recordings. For each song (and each recording the description \
    names), report briefly:
    - the recording (artist, album, year) and electric guitarist(s), if found
    - amp(s) and cab, drives/boosts and how hard they're pushed, modulation, delays (note value, e.g. dotted eighth, \
    and repeats), reverbs (type and size), and anything distinctive (swells, ebow, octave, tremolo, a clean vs. driven part)
    - how sure you are: "documented" (from a rig rundown, interview or tutorial) or "inferred" (from the genre, era \
    or how it sounds by reputation)

    Keep it short and factual: notes, not prose. No more than about 150 words per song. Don't invent gear; when \
    nothing is documented, say so and give the usual approach for that style. End with one line naming the main sources.
    """

    /// Looks up the gear and settings on the recordings named in the description and the set's songs (web search).
    static func research(description: String, songs: [HelixSong], model: String, effort: String) async throws -> String {
        var msg = "<request>\n\(description)\n</request>\n"
        if !songs.isEmpty {
            msg += "\n<songs>\n" + songs.enumerated().map { i, s in
                ["\(i). \(s.title)", s.artist.map { "written by \($0)" }, s.key.map { "key \($0)" }, s.bpm.map { "\($0) BPM" }]
                    .compactMap { $0 }.joined(separator: " · ")
            }.joined(separator: "\n") + "\n</songs>\n"
        }
        let searches = min(20, 5 + 2 * songs.count)
        return try await Claude.ask(system: researchSystem, content: [["type": "text", "text": msg]], effort: effort,
                                    maxTokens: maxTokens(effort, base: 12000), model: model,
                                    tools: [["type": "web_search_20260209", "name": "web_search", "max_uses": searches]])
    }

    /// Room for thinking at the higher efforts.
    static func maxTokens(_ effort: String, base: Int) -> Int {
        switch effort {
        case "xhigh": return base * 2
        case "max": return base * 3
        default: return base
        }
    }

    static func design(description: String, songs: [HelixSong], catalog: HelixCatalog,
                       volumePedal: Bool = false, knobs: Int = 3, switches: Int = 4, research: String? = nil,
                       model: String = Claude.model, effort: String = "high",
                       guitarBlock: Bool = false, guitars: [String] = [], revision: Revision? = nil) async throws -> HelixDesign {
        var msg = "<catalog>\n\(catalog.promptText)\n</catalog>\n\n<request>\n\(description)\n</request>\n"
        if let research, !research.isEmpty {
            msg += "\n<tone_research>\n\(research)\n</tone_research>\n"
        }
        let firstKnob = volumePedal ? 2 : 1
        let lastKnob = HelixBuilder.lastAIKnob(knobs, guitarBlock: guitarBlock)
        msg += "\nLive controls available: "
            + (lastKnob >= firstKnob ? "Knobs \(firstKnob)–\(lastKnob)" : "no knobs")
            + (switches > 0 ? ", Switches 1–\(switches)." : ", no switches.")
        if HelixBuilder.driveKnob, lastKnob >= 2 {
            msg += " Knob 2 is the player's drive knob: include at least one drive / boost / fuzz block and put Knob 2 on "
                + "its gain (Gain, Drive, Fuzz or Sustain), sweeping from a light push to plenty, so the player can pull "
                + "the drive back or dig in per song and section. Use the other knobs for anything else."
        }
        var added: [String] = []
        if guitarBlock { added.append("a guitar EQ (first, on Knobs 14–16)") }
        if volumePedal { added.append("the player's volume pedal (on Knob 1)") }
        if !added.isEmpty {
            msg += " StageCharts adds " + added.joined(separator: " and ") + " before your blocks."
        }
        if HelixBuilder.twoDSP {
            msg += " Positions: Helix has two DSPs. StageCharts puts your blocks before the first amp or preamp on the "
                + "first DSP (\(8 - added.count) positions there) and the amp and everything after it on the second (8 "
                + "positions). An amp inside a split path takes the whole split to the second DSP. With no amp, everything "
                + "is on the first DSP. Use the room for a fuller pedalboard or a second amp when the tones call for it, not "
                + "to fill positions."
        } else {
            msg += " Positions: \(8 - added.count) in total."
        }
        msg += HelixBuilder.evenLevels
            ? " Levels: StageCharts evens out amp channel volumes (ChVol / Ch Vol) and cab levels afterwards, so leave "
                + "those at the examples; make level changes between snapshots with a volume or gain block, not the amp's channel volume."
            : " Levels: keep amp channel volumes near the examples."
        msg += "\n"
        if !guitars.isEmpty {
            msg += "\n<guitars>\n" + guitars.map { "- \($0)" }.joined(separator: "\n") + "\n</guitars>\n"
        }
        if !songs.isEmpty {
            msg += "\n<songs>\n"
            for (i, s) in songs.enumerated() {
                var parts = ["\(i). \(s.title)"]
                if let a = s.artist { parts.append("by \(a)") }
                if let k = s.key { parts.append("key \(k)") }
                if let b = s.bpm { parts.append("\(b) BPM") }
                if let t = s.time { parts.append(t) }
                if !s.note.isEmpty { parts.append("note: \(s.note)") }
                msg += parts.joined(separator: " · ") + "\n"
            }
            msg += "</songs>\n"
        }
        if let revision {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            let current = String(decoding: try enc.encode(revision.current), as: UTF8.self)
            msg += "\n<current_preset>\n\(current)\n</current_preset>\n"
            msg += "\n<history>\n" + revision.history.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                + "\n</history>\n"
            msg += "\n<change>\n\(revision.change)\n</change>\n"
            msg += "\nThis is a revision. The player has been refining the current preset over time (the history lists "
                + "each step in order), and now wants the change above. Make that change and return the whole preset. "
                + "Keep everything the change doesn't touch exactly as it is: the same blocks in the same order and lanes, "
                + "their settings, the snapshots (names, on/off, settings), the song-to-snapshot mapping and the live "
                + "controls. Block indices in snapshots and controls refer to the blocks you return. Keep the name unless "
                + "the change asks for a new one. Write `summary` as a sentence or two on what changed and why.\n"
        }
        let text = try await Claude.ask(system: system, content: [["type": "text", "text": msg]],
                                        effort: effort, schema: schema, maxTokens: maxTokens(effort, base: 16000), model: model)
        guard let d = text.data(using: .utf8) else { throw AIError.empty }
        return try JSONDecoder().decode(HelixDesign.self, from: d)
    }
}

// MARK: - Building the .hlx

enum HelixBuilder {
    struct Result {
        var preset: JSON
        var warnings: [String]
        /// Song index → snapshot index (0-based) after clean-up.
        var songSnapshots: [Int: Int]
        var blocks: [String]
        var snapshotNames: [String]
        /// "Knob 1: Volume Pedal Position", "Switch 1: Heliosphere on/off", …
        var controls: [String] = []
    }

    /// The volume pedal StageCharts puts first when the player asks for one: their own, else Helix's Volume Pedal.
    static func volumeModel(_ catalog: HelixCatalog) -> String? {
        ["HD2_VolPanVol", "HD2_VolPanVolStereo"].first { catalog.models[$0] != nil }
            ?? catalog.models.keys.sorted().first { $0.hasPrefix("HD2_VolPanVol") }
    }

    /// The guitar EQ StageCharts puts first: its level, low and high gains follow Knobs 14–16, which StageCharts sets
    /// over MIDI for the guitar being played (see Guitars.swift).
    static let guitarModel = "HD2_EQLowShelfHighShelf"
    static let guitarKnobs: [(knob: Int, param: String, name: String)] = [(14, "Level", "level"), (15, "LowGain", "low"),
                                                                          (16, "HighGain", "high")]
    static let guitarRange = 12.0           // each guitar knob sweeps -12…+12 dB
    /// The highest knob Claude may use (Knobs 14–16 are the guitar's when the guitar block is on).
    static func lastAIKnob(_ knobs: Int, guitarBlock: Bool) -> Int { guitarBlock ? min(knobs, 13) : knobs }
    /// Knob 2 always rides a drive pedal's gain (Settings → Helix → Live controls).
    static var driveKnob: Bool { UserDefaults.standard.object(forKey: "helixDriveKnob") as? Bool ?? true }

    /// Settings → Helix → Levels: bring amp channel volumes and cab levels up to where hand-built presets sit.
    static var evenLevels: Bool { UserDefaults.standard.object(forKey: "helixEvenLevels") as? Bool ?? true }
    /// The preset's output level in dB (the main output block's gain), to match hand-built presets.
    static var outputLevel: Double { UserDefaults.standard.double(forKey: "helixOutputLevel") }
    /// Pedals on DSP 1, the amp and everything after it on DSP 2 (like a hand-built two-DSP preset).
    static var twoDSP: Bool { UserDefaults.standard.object(forKey: "helixTwoDSP") as? Bool ?? true }
    /// The loudest snapshot's amp channel volume after evening out (hand-built presets sit around 0.9).
    static let levelTarget = 0.85
    static let channelVolumeParams = ["ChVol", "Ch Vol"]
    /// Cabs left at 0 dB go to this (hand-built presets use about +3 dB).
    static let cabLevel = 2.5
    static func raiseCabLevel(_ cab: inout JSON) {
        if let l = cab["Level"].flatMap(HelixCatalog.number), l == 0 { cab["Level"] = cabLevel }
    }
    static func isAmp(_ id: String) -> Bool { id.hasPrefix("HD2_Amp") || id.hasPrefix("HD2_Preamp") }

    /// One DSP's chain: series blocks, the two split paths, series blocks after the merge.
    struct Layout {
        typealias Kept = (index: Int, model: HelixCatalog.Model, block: HelixDesign.Block)
        var pre: [Kept] = [], laneA: [Kept] = [], laneB: [Kept] = [], post: [Kept] = []
        var width: Int { pre.count + max(laneA.count, laneB.count) + post.count }
        var isEmpty: Bool { width == 0 }
        /// Where the merge sits (the end of the chain when there's no path B).
        var joinAt: Int { laneB.isEmpty ? 8 : pre.count + max(laneA.count, laneB.count) }
        /// Drops the last block that fits least; returns its model id.
        mutating func dropLast() -> String {
            let dropped: Kept
            if !post.isEmpty { dropped = post.removeLast() }
            else if laneA.count >= laneB.count, !laneA.isEmpty { dropped = laneA.removeLast() }
            else if !laneB.isEmpty { dropped = laneB.removeLast() }
            else { dropped = pre.removeLast() }
            if laneB.isEmpty { pre += laneA + post; laneA = []; post = [] }
            return dropped.model.id
        }
    }

    static func build(_ design: HelixDesign, catalog: HelixCatalog, songCount: Int, volumePedal: Bool = false,
                      knobs: Int = 3, switches: Int = 4, guitarBlock: Bool = false) throws -> Result {
        var warnings: [String] = []
        var design = design
        var volumeIndex: Int?, guitarIndex: Int?
        if volumePedal {
            if let v = volumeModel(catalog) { design = design.withBlockFirst(v); volumeIndex = 0 }
            else { warnings.append("Your Helix presets don't include a volume pedal, so none was added.") }
        }
        if guitarBlock {
            if catalog.models[guitarModel] != nil {
                design = design.withBlockFirst(guitarModel, why: "Matches your guitar (set by StageCharts)",
                                               settings: [.init(param: "LowFreq", value: 150), .init(param: "HighFreq", value: 3000),
                                                          .init(param: "LowGain", value: 0), .init(param: "HighGain", value: 0),
                                                          .init(param: "Level", value: 0)],
                                               stereo: false, replacing: false)
                guitarIndex = 0
                volumeIndex = volumeIndex.map { $0 + 1 }
            } else {
                warnings.append("Your Helix presets don't include the Low/High Shelf EQ, so no guitar block was added.")
            }
        }
        var preset = catalog.skeleton
        var data = preset["data"] as? JSON ?? [:]
        var tone = data["tone"] as? JSON ?? [:]
        var dsps: [JSON] = [tone["dsp0"] as? JSON ?? [:], tone["dsp1"] as? JSON ?? [:]]

        // Blocks Claude picked that this Helix actually has.
        var kept: [(index: Int, model: HelixCatalog.Model, block: HelixDesign.Block)] = []
        for (i, b) in design.blocks.enumerated() {
            if let m = catalog.models[b.model] { kept.append((i, m, b)) }
            else { warnings.append("Left out \(b.model): it isn't in your Helix presets.") }
        }
        guard !kept.isEmpty else { throw HelixError.bad("Claude didn't pick any models from your Helix. Try again.") }

        // Layout: series blocks before the split, paths A and B side by side, series blocks after the merge.
        typealias Kept = (index: Int, model: HelixCatalog.Model, block: HelixDesign.Block)
        let parallel = kept.contains { $0.block.lane == "B" }
        let firstParallel = parallel ? kept.firstIndex { $0.block.lane == "A" || $0.block.lane == "B" } : nil
        var pre: [Kept] = [], laneA: [Kept] = [], laneB: [Kept] = [], post: [Kept] = []
        for (i, k) in kept.enumerated() {
            switch (parallel ? k.block.lane : nil) {
            case "A"?: laneA.append(k)
            case "B"?: laneB.append(k)
            default: if let f = firstParallel, i > f { post.append(k) } else { pre.append(k) }
            }
        }
        if laneB.isEmpty { pre += laneA + post; laneA = []; post = [] }       // no path B: one straight chain

        // With both DSPs: the pedals before the first amp on DSP 1, the amp and everything after it on DSP 2 (an amp
        // inside a split path takes the whole split along). Each DSP has 8 positions.
        var dsp = [Self.Layout(pre: pre, laneA: laneA, laneB: laneB, post: post), Self.Layout()]
        if twoDSP {
            if let i = pre.firstIndex(where: { isAmp($0.model.id) }), i > 0 {
                dsp = [.init(pre: Array(pre[..<i])), .init(pre: Array(pre[i...]), laneA: laneA, laneB: laneB, post: post)]
            } else if !pre.isEmpty, (laneA + laneB).contains(where: { isAmp($0.model.id) }) {
                dsp = [.init(pre: pre), .init(laneA: laneA, laneB: laneB, post: post)]
            } else if !pre.contains(where: { isAmp($0.model.id) }), !(laneA + laneB).contains(where: { isAmp($0.model.id) }),
                      let j = post.firstIndex(where: { isAmp($0.model.id) }) {
                dsp = [.init(pre: pre, laneA: laneA, laneB: laneB, post: Array(post[..<j])), .init(pre: Array(post[j...]))]
            }
        }
        for d in 0..<2 {
            while dsp[d].width > 8 {
                let name = dsp[d].dropLast()
                warnings.append("Left out \(HelixCatalog.displayName(name)): "
                    + (dsp[1].isEmpty ? "the chain only has 8 positions." : "DSP \(d + 1) only has 8 positions."))
            }
        }
        let chained = !dsp[1].isEmpty
        var place: [(dsp: Int, path: Int, position: Int, local: Int)] = []
        kept = []
        for d in 0..<2 {
            let l = dsp[d]
            var local = 0
            for (n, k) in l.pre.enumerated() { kept.append(k); place.append((d, 0, n, local)); local += 1 }
            for (n, k) in l.laneA.enumerated() { kept.append(k); place.append((d, 0, l.pre.count + n, local)); local += 1 }
            for (n, k) in l.laneB.enumerated() { kept.append(k); place.append((d, 1, l.pre.count + n, local)); local += 1 }
            for (n, k) in l.post.enumerated() { kept.append(k); place.append((d, 0, l.joinAt + n, local)); local += 1 }
        }
        let newIndex = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1.index, $0) })
        /// Where block `bi` lives: "dsp1", "block2" → automation refers to it as "dsp1.block2".
        func dspKey(_ bi: Int) -> String { "dsp\(place[bi].dsp)" }
        func blockKey(_ bi: Int) -> String { "block\(place[bi].local)" }
        func ref(_ bi: Int) -> String { "\(dspKey(bi)).\(blockKey(bi))" }
        func blockJSON(_ bi: Int) -> JSON? { dsps[place[bi].dsp][blockKey(bi)] as? JSON }
        func isStereo(_ bi: Int) -> Bool { blockJSON(bi)?["@stereo"] as? Bool ?? false }

        let snaps = Array(design.snapshots.prefix(8))
        guard !snaps.isEmpty else { throw HelixError.bad("Claude didn't make any snapshots. Try again.") }

        // Values per (block, param) across snapshots, to find which ones snapshots control.
        var perSnapshot: [Int: [String: [Int: Any]]] = [:]       // block → param → snapshot → value
        var cabCount = [0, 0]
        for (bi, k) in kept.enumerated() {
            var block = k.model.example
            block["@position"] = place[bi].position
            block["@path"] = place[bi].path
            block["@enabled"] = snaps[0].enabled.indices.contains(k.index) ? snaps[0].enabled[k.index] : true
            block["@no_snapshot_bypass"] = false
            if let want = k.block.stereo, block["@stereo"] != nil {
                let can = catalog.channels[k.model.id] ?? [true, true]
                if can[want ? 1 : 0] { block["@stereo"] = want }
                else { warnings.append("\(HelixCatalog.displayName(k.model.id)) only runs \(want ? "mono" : "stereo"), so it stays that way.") }
            }
            let stereo = block["@stereo"] as? Bool ?? false
            for s in k.block.settings {
                guard let v = value(s.value, param: s.param, model: k.model, stereo: stereo, catalog: catalog, warnings: &warnings) else {
                    warnings.append("\(HelixCatalog.displayName(k.model.id)): ignored unknown setting \(s.param)."); continue
                }
                block[s.param] = v
            }
            if evenLevels, k.model.type == 2 { Self.raiseCabLevel(&block) }
            if let ref = block["@cab"] as? String, var cab = k.model.linked[ref] {
                if let other = k.block.cab, other != cab["@model"] as? String {
                    if let c = catalog.linkedCab(other) { cab = c; cab["@enabled"] = true }
                    else { warnings.append("\(HelixCatalog.displayName(k.model.id)): kept its own cab (\(other) isn't a cab in your Helix).") }
                }
                if evenLevels { Self.raiseCabLevel(&cab) }
                let d = place[bi].dsp
                let name = "cab\(cabCount[d])"; cabCount[d] += 1
                block["@cab"] = name
                dsps[d][name] = cab
            } else if let other = k.block.cab, !other.isEmpty {
                warnings.append("\(HelixCatalog.displayName(k.model.id)) has no cab of its own, so \(HelixCatalog.displayName(other)) wasn't used.")
            }
            dsps[place[bi].dsp][blockKey(bi)] = block
        }
        for (si, s) in snaps.enumerated() {
            for st in s.settings {
                guard let bi = newIndex[st.block] else { continue }
                guard let v = value(st.value, param: st.param, model: kept[bi].model, stereo: isStereo(bi), catalog: catalog,
                                    warnings: &warnings, snapshot: clean(s.name, max: 10)) else { continue }
                perSnapshot[bi, default: [:]][st.param, default: [:]][si] = v
            }
        }

        // Even out levels: each amp's loudest channel volume (block or any snapshot) is brought up to the target,
        // scaling the others with it so quieter snapshots stay quieter. Master is left alone (it changes the tone).
        if evenLevels {
            for (bi, k) in kept.enumerated() where isAmp(k.model.id) {
                guard var block = blockJSON(bi) else { continue }
                for p in Self.channelVolumeParams where k.model.example[p] != nil {
                    var bySnap = perSnapshot[bi]?[p] ?? [:]
                    let base = block[p].flatMap(HelixCatalog.number) ?? 0
                    let peak = ([base] + bySnap.values.compactMap(HelixCatalog.number)).max() ?? 0
                    guard peak > 0, peak < Self.levelTarget else { continue }
                    let f = Self.levelTarget / peak, l = catalog.limits[k.model.id]?[p]
                    func scaled(_ x: Double) -> Double { l?.clamp(x * f, stereo: false) ?? Swift.min(x * f, 1) }
                    block[p] = scaled(base)
                    for (si, v) in bySnap { if let x = HelixCatalog.number(v) { bySnap[si] = scaled(x) } }
                    if !bySnap.isEmpty { perSnapshot[bi]?[p] = bySnap }
                }
                dsps[place[bi].dsp][blockKey(bi)] = block
            }
        }

        // Snapshot-controlled values (controller 19): any setting a snapshot changes.
        var controller: [JSON] = [[:], [:]]          // per DSP: block → param → assignment
        var controlled: [Int: [String: [Any]]] = [:]          // block → param → value per snapshot
        for (bi, params) in perSnapshot {
            var bc: JSON = [:]
            for (p, bySnap) in params {
                let base = blockJSON(bi)?[p] ?? 0
                let values = snaps.indices.map { bySnap[$0] ?? base }
                controlled[bi, default: [:]][p] = values
                if var block = blockJSON(bi) {      // the block itself shows snapshot 1's value
                    block[p] = values[0]; dsps[place[bi].dsp][blockKey(bi)] = block
                }
                let nums = values.compactMap { HelixCatalog.number($0) }
                var entry: JSON = ["@controller": 19, "@snapshot_disable": false]
                if HelixCatalog.isBool(base) {
                    entry["@min"] = false; entry["@max"] = true
                } else {
                    if let l = catalog.limits[kept[bi].model.id]?[p] {      // Helix Native's own range
                        entry["@min"] = l.lo
                        entry["@max"] = isStereo(bi) ? (l.hiStereo ?? l.hi) : l.hi
                    } else {
                        let r = kept[bi].model.ranges[p] ?? (nums.min() ?? 0, nums.max() ?? 1)
                        let lo = min(r.0, nums.min() ?? r.0), hi = max(r.1, nums.max() ?? r.1)
                        let unit = lo >= 0 && hi <= 1          // most knobs are 0–1: give the snapshot the full range
                        entry["@min"] = unit ? 0.0 : lo
                        entry["@max"] = unit ? 1.0 : hi
                    }
                }
                bc[p] = entry
            }
            if !bc.isEmpty { controller[place[bi].dsp][blockKey(bi)] = bc }
        }
        func controls(_ bi: Int) -> JSON? { controller[place[bi].dsp][blockKey(bi)] as? JSON }
        // Expression pedals (wahs, volume): the player's own assignments. A snapshot-controlled setting can't also follow a pedal.
        for (bi, k) in kept.enumerated() {
            for (p, entry) in catalog.pedalAssignments(for: k.model.id) {
                var bc = controls(bi) ?? [:]
                if bc[p] != nil {
                    warnings.append("\(HelixCatalog.displayName(k.model.id)) \(p) changes with snapshots, so it isn't on your expression pedal.")
                    continue
                }
                var e = entry
                e["@snapshot_disable"] = false
                bc[p] = e
                controller[place[bi].dsp][blockKey(bi)] = bc
            }
        }
        // Live controls: Helix Native's automation Knobs (slots 0–15) and Switches (16–31), driven by the player's MIDI
        // controller through the DAW. Stored positionally in tone.automation.@assignments.
        var slots: [Int: JSON] = [:]
        var controlNames: [String] = []
        func label(_ bi: Int) -> String { HelixCatalog.displayName(kept[bi].model.id) }
        if let gi = guitarIndex, let bi = newIndex[gi] {
            for g in guitarKnobs {
                slots[g.knob - 1] = ["@param": "\(ref(bi)).\(g.param)", "@min": -guitarRange, "@max": guitarRange]
                controlNames.append("Knob \(g.knob): guitar \(g.name) (set by StageCharts for your guitar)")
            }
        }
        let aiKnobs = lastAIKnob(knobs, guitarBlock: guitarIndex != nil)
        if let vi = volumeIndex, knobs >= 1, let bi = newIndex[vi], kept[bi].model.id.hasPrefix("HD2_VolPanVol"),
           kept[bi].model.example["Pedal"] != nil {
            slots[0] = ["@param": "\(ref(bi)).Pedal", "@min": 0.0, "@max": 1.0]
            controlNames.append("Knob 1: \(label(bi)) (your volume pedal)")
        }
        for c in design.controls ?? [] {
            guard let bi = newIndex[c.block] else { continue }
            if c.kind == "switch" {
                guard switches >= 1, (1...switches).contains(c.number), slots[15 + c.number] == nil else { continue }
                slots[15 + c.number] = ["@param": "\(ref(bi)).@enabled", "@min": false, "@max": true]
                controlNames.append("Switch \(c.number): \(label(bi)) on/off")
            } else {
                if c.number == 2, driveKnob, !kept[bi].model.id.contains("Dist") {
                    warnings.append("Knob 2 is your drive knob, so it wasn't put on \(label(bi)) \(c.param).")
                    continue
                }
                guard aiKnobs >= 1, (1...aiKnobs).contains(c.number), slots[c.number - 1] == nil,
                      let ex = kept[bi].model.example[c.param], !c.param.hasPrefix("@"), !HelixCatalog.isBool(ex) else { continue }
                if controls(bi)?[c.param] != nil {
                    warnings.append("Knob \(c.number) left unassigned: \(label(bi)) \(c.param) changes with snapshots.")
                    continue
                }
                let l = catalog.limits[kept[bi].model.id]?[c.param]
                var lo = Swift.min(c.min, c.max), hi = Swift.max(c.min, c.max)
                if let l { lo = l.clamp(lo, stereo: isStereo(bi)); hi = l.clamp(hi, stereo: isStereo(bi)) }
                let int = HelixCatalog.isInteger(ex)
                slots[c.number - 1] = ["@param": "\(ref(bi)).\(c.param)",
                                       "@min": int ? Int(lo.rounded()) as Any : lo, "@max": int ? Int(hi.rounded()) as Any : hi]
                controlNames.append("Knob \(c.number): \(label(bi)) \(c.param) (\(HelixCatalog.short(lo))–\(HelixCatalog.short(hi)))")
            }
        }
        // Knob 2 = the drive's gain (Settings → Helix), if Claude didn't already assign it.
        if driveKnob, aiKnobs >= 2, slots[1] == nil {
            let gainParams = ["Gain", "Drive", "Fuzz", "Sustain", "Boost"]
            let pick = kept.indices.lazy.compactMap { bi -> (Int, String)? in
                guard kept[bi].model.id.contains("Dist") else { return nil }
                let snap = controls(bi)
                guard let p = gainParams.first(where: { kept[bi].model.example[$0] != nil && snap?[$0] == nil }) else { return nil }
                return (bi, p)
            }.first
            if let (bi, p) = pick {
                let l = catalog.limits[kept[bi].model.id]?[p]
                let lo = l?.lo ?? 0, hi = l?.hi ?? 1
                slots[1] = ["@param": "\(ref(bi)).\(p)", "@min": lo, "@max": hi]
                controlNames.append("Knob 2: \(label(bi)) \(p) (your drive knob)")
            } else {
                warnings.append("No drive pedal in this preset, so Knob 2 (your drive knob) does nothing.")
            }
        }
        for (bi, k) in kept.enumerated() where k.model.category.hasPrefix("wah")
            && !slots.values.contains(where: { ($0["@param"] as? String) == "\(ref(bi)).Pedal" }) {
            warnings.append("\(label(bi)) has no knob on its Pedal, so it stays parked where it is.")
        }
        if let last = slots.keys.max() {
            tone["automation"] = ["@assignments": (0...last).map { slots[$0] as Any? ?? NSNull() }]
        } else {
            tone["automation"] = nil
        }
        controlNames.sort { a, b in
            let ka = a.hasPrefix("Knob"), kb = b.hasPrefix("Knob")
            return ka != kb ? ka : a.localizedStandardCompare(b) == .orderedAscending
        }

        // Each DSP's split and merge (always present in Helix; at the ends of the chain when its path B isn't used).
        let pj = design.paths ?? .init(levelA: 0, panA: 0.5, levelB: 0, panB: 0.5, invertB: false)
        func level(_ x: Double) -> Double { min(max(x, -60), 12) }
        func pan(_ x: Double) -> Double { min(max(x, 0), 1) }
        for d in 0..<2 {
            let l = dsp[d], split = !l.laneB.isEmpty
            dsps[d]["split"] = ["@enabled": true, "@model": "HD2_AppDSPFlowSplitY", "@position": split ? l.pre.count : 0,
                                "BalanceA": 0.5, "BalanceB": 0.5, "bypass": false]
            dsps[d]["join"] = ["@enabled": true, "@model": "HD2_AppDSPFlowJoin", "@position": l.joinAt,
                               "A Level": split ? level(pj.levelA) : 0.0, "A Pan": split ? pan(pj.panA) : 0.5,
                               "B Level": split ? level(pj.levelB) : 0.0, "B Pan": split ? pan(pj.panB) : 0.5,
                               "B Polarity": split ? pj.invertB : false, "Level": 0.0]
        }
        // Routing: DSP 1's path A feeds DSP 2 when both are used; the last one goes to the main output, at the
        // player's preset output level.
        func output(_ d: Int, to out: Int, gain: Double) {
            var o = dsps[d]["outputA"] as? JSON ?? ["@model": "HD2_AppDSPFlowOutput", "pan": 0.5]
            o["@output"] = out
            o["gain"] = gain
            dsps[d]["outputA"] = o
        }
        let gain = Swift.min(Swift.max(outputLevel, -20), 20)
        output(0, to: chained ? 2 : 1, gain: chained ? 0 : gain)
        output(1, to: 1, gain: chained ? gain : 0)
        if chained, var input = dsps[1]["inputA"] as? JSON {
            input["@input"] = 0            // fed by DSP 1 (as Helix Native writes it)
            dsps[1]["inputA"] = input
        }
        tone["dsp0"] = dsps[0]
        tone["dsp1"] = dsps[1]
        let controllerJSON = Dictionary(uniqueKeysWithValues: (0..<2).filter { !controller[$0].isEmpty }
            .map { ("dsp\($0)", controller[$0] as Any) })
        tone["controller"] = controllerJSON.isEmpty ? nil : controllerJSON

        // Snapshots 1–8 (unused ones are copies of the first, marked not valid).
        var names: [String] = []
        for si in 0..<8 {
            let s = si < snaps.count ? snaps[si] : snaps[0]
            var blocks: [JSON] = [["split": true], ["split": true]]     // Helix Native saves each split's on/off
            for (bi, k) in kept.enumerated() {
                blocks[place[bi].dsp][blockKey(bi)] = s.enabled.indices.contains(k.index) ? s.enabled[k.index] : true
            }
            var ctl: [JSON] = [[:], [:]]
            for (bi, params) in controlled {
                var b: JSON = [:]
                for (p, values) in params { b[p] = ["@fs_enabled": false, "@value": values[si < snaps.count ? si : 0]] }
                ctl[place[bi].dsp][blockKey(bi)] = b
            }
            let name = si < snaps.count ? clean(s.name, max: 10) : "SNAPSHOT \(si + 1)"
            if si < snaps.count { names.append(name) }
            var snap: JSON = ["@name": name, "@custom_name": si < snaps.count, "@valid": si < snaps.count,
                              "@ledcolor": 0, "@pedalstate": 2, "@tempo": s.tempo ?? 120.0,
                              "blocks": ["dsp0": blocks[0], "dsp1": blocks[1]]]
            let ctlJSON = Dictionary(uniqueKeysWithValues: (0..<2).filter { !ctl[$0].isEmpty }.map { ("dsp\($0)", ctl[$0] as Any) })
            if !ctlJSON.isEmpty { snap["controllers"] = ctlJSON }
            tone["snapshot\(si)"] = snap
        }
        if var global = tone["global"] as? JSON {
            global["@current_snapshot"] = 0
            global["@cursor_dsp"] = 0
            global["@cursor_group"] = "block0"
            global["@tempo"] = snaps[0].tempo ?? 120.0
            global["@topology0"] = dsp[0].laneB.isEmpty ? "A" : "SABJ"
            global["@topology1"] = dsp[1].laneB.isEmpty ? "A" : "SABJ"
            tone["global"] = global
        }
        data["tone"] = tone
        var meta = data["meta"] as? JSON ?? [:]
        meta["name"] = clean(design.name, max: 16)
        meta["modifieddate"] = Int(Date().timeIntervalSince1970)
        meta["author"] = "StageCharts"
        data["meta"] = meta
        preset["data"] = data

        var map: [Int: Int] = [:]
        for s in design.songs where s.song >= 0 && s.song < songCount {
            map[s.song] = min(max(0, s.snapshot), snaps.count - 1)
        }
        return Result(preset: preset, warnings: warnings, songSnapshots: map,
                      blocks: kept.map { HelixCatalog.describe($0.model.id) }, snapshotNames: names, controls: controlNames)
    }

    /// Claude's number as the parameter's own type (on/off, whole number or decimal); nil for unknown settings.
    /// Values outside Helix Native's limits are pulled inside them (Helix would clamp them anyway), with a warning.
    private static func value(_ x: Double, param: String, model: HelixCatalog.Model, stereo: Bool, catalog: HelixCatalog,
                              warnings: inout [String], snapshot: String? = nil) -> Any? {
        guard let example = model.example[param], !param.hasPrefix("@") else { return nil }
        if HelixCatalog.isBool(example) { return x >= 0.5 }
        var x = x
        if let l = catalog.limits[model.id]?[param] {
            let c = l.clamp(x, stereo: stereo)
            if abs(c - x) > 1e-9 {
                let w = "\(HelixCatalog.displayName(model.id)) \(param)\(snapshot.map { " (\($0))" } ?? ""): "
                    + "\(HelixCatalog.short(x)) is outside its range, so it's set to \(HelixCatalog.short(c))."
                warnings.append(w)
                x = c
            }
        }
        if HelixCatalog.isInteger(example) { return Int(x.rounded()) }
        return x
    }

    /// Helix names: limited length and characters.
    static func clean(_ s: String, max: Int) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_+=!@#$&()?:'\",./ ")
        let t = String(s.filter { allowed.contains($0) }.prefix(max)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "StageCharts" : t
    }

    /// Writes the preset into the library's Helix folder; returns the file.
    /// With `replacing`, writes over that file (a new version of a preset that has a history).
    static func save(_ preset: JSON, name: String, in folder: URL, replacing: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let replacing {
            let url = folder.appendingPathComponent(replacing)
            let d = try JSONSerialization.data(withJSONObject: preset, options: [.prettyPrinted, .sortedKeys])
            try d.write(to: url, options: .atomic)
            return url
        }
        var url = folder.appendingPathComponent(clean(name, max: 40) + ".hlx")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(clean(name, max: 40) + " \(n).hlx"); n += 1
        }
        let d = try JSONSerialization.data(withJSONObject: preset, options: [.prettyPrinted, .sortedKeys])
        try d.write(to: url, options: .atomic)
        return url
    }
}
