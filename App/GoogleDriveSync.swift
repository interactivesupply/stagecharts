import Foundation
import AuthenticationServices
import CryptoKit
import Security
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Google Drive sync without the Files app: StageCharts signs in with Google (OAuth + PKCE, scope
// drive.file — only files this app creates) and mirrors the library to "StageCharts Library" in Drive.

// MARK: - Sign-in

@MainActor
final class GoogleAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var email: String?
    @Published private(set) var isSignedIn = false

    /// From Info.plist (StageChartsGoogleClientID) — an iOS-type OAuth client for com.bradlinger.stagecharts.
    let clientID = (Bundle.main.object(forInfoDictionaryKey: "StageChartsGoogleClientID") as? String)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    var isConfigured: Bool { clientID.hasSuffix(".apps.googleusercontent.com") }

    private var redirectScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    private var redirectURI: String { redirectScheme + ":/oauth2redirect" }
    private static let scopes = "openid email https://www.googleapis.com/auth/drive.file"

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var session: ASWebAuthenticationSession?

    override init() {
        super.init()
        email = UserDefaults.standard.string(forKey: "googleEmail")
        isSignedIn = Keychain.read("refreshToken") != nil
    }

    func signIn() async throws {
        guard isConfigured else { throw DriveError.notConfigured }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: redirectScheme) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? DriveError.cancelled) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            s.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else { throw DriveError.cancelled }
        let json = try await tokenRequest(["code": code, "code_verifier": verifier,
                                           "grant_type": "authorization_code", "redirect_uri": redirectURI])
        guard let refresh = json["refresh_token"] as? String else { throw DriveError.message("Google didn't return a refresh token.") }
        Keychain.write("refreshToken", refresh)
        apply(json)
        if let id = json["id_token"] as? String, let mail = Self.email(fromIDToken: id) {
            email = mail
            UserDefaults.standard.set(mail, forKey: "googleEmail")
        }
        isSignedIn = true
    }

    func signOut() {
        Keychain.delete("refreshToken")
        UserDefaults.standard.removeObject(forKey: "googleEmail")
        accessToken = nil; email = nil; isSignedIn = false
    }

    /// A valid access token (refreshed when needed).
    func token() async throws -> String {
        if let accessToken, Date() < expiry.addingTimeInterval(-60) { return accessToken }
        guard let refresh = Keychain.read("refreshToken") else { throw DriveError.notSignedIn }
        let json = try await tokenRequest(["refresh_token": refresh, "grant_type": "refresh_token"])
        apply(json)
        guard let accessToken else { throw DriveError.notSignedIn }
        return accessToken
    }

    private func apply(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
    }

    private func tokenRequest(_ params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = params; all["client_id"] = clientID
        req.httpBody = all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            if (json["error"] as? String) == "invalid_grant" { signOut() }
            throw DriveError.message("Google sign-in failed: \(json["error_description"] ?? json["error"] ?? "unknown error")")
        }
        return json
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first ?? ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var g = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in chars.randomElement(using: &g)! })
    }

    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }
}

enum DriveError: LocalizedError {
    case notConfigured, notSignedIn, cancelled, message(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Google sign-in isn't set up in this build yet."
        case .notSignedIn: return "Not signed in to Google Drive."
        case .cancelled: return "Sign-in was cancelled."
        case .message(let m): return m
        }
    }
}

enum Keychain {
    private static let service = "StageCharts.Google"
    static func write(_ key: String, _ value: String) {
        delete(key)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key,
                    kSecValueData: Data(value.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary, nil)
    }
    static func read(_ key: String) -> String? {
        var out: AnyObject?
        let q = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key,
                 kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary
        guard SecItemCopyMatching(q, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ key: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key] as CFDictionary)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Drive REST API (v3)

struct DriveFile: Decodable {
    let id: String
    let name: String
    let md5Checksum: String?
    let modifiedTime: String?
}

@MainActor
struct DriveAPI {
    let auth: GoogleAuth
    private static let folderMime = "application/vnd.google-apps.folder"

    private func send(_ req: URLRequest) async throws -> Data {
        var r = req
        r.setValue("Bearer \(try await auth.token())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw DriveError.message("Google Drive error \(code): " + (String(data: data, encoding: .utf8)?.prefix(200) ?? ""))
        }
        return data
    }

    func list(in folder: String) async throws -> [DriveFile] {
        struct Page: Decodable { let files: [DriveFile]; let nextPageToken: String? }
        var out: [DriveFile] = [], token: String?
        repeat {
            var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            c.queryItems = [.init(name: "q", value: "'\(folder)' in parents and trashed=false"),
                            .init(name: "fields", value: "nextPageToken,files(id,name,md5Checksum,modifiedTime,mimeType)"),
                            .init(name: "pageSize", value: "1000"), .init(name: "spaces", value: "drive")]
            if let token { c.queryItems?.append(.init(name: "pageToken", value: token)) }
            let page = try JSONDecoder().decode(Page.self, from: try await send(URLRequest(url: c.url!)))
            out += page.files; token = page.nextPageToken
        } while token != nil
        return out
    }

    /// Finds (or creates) a folder this app made, by name under `parent` ("root" = My Drive).
    func folder(named name: String, in parent: String) async throws -> String {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let safe = name.replacingOccurrences(of: "'", with: "\\'")
        c.queryItems = [.init(name: "q", value: "name='\(safe)' and mimeType='\(Self.folderMime)' and '\(parent)' in parents and trashed=false"),
                        .init(name: "fields", value: "files(id,name)")]
        struct R: Decodable { let files: [DriveFile] }
        if let f = try JSONDecoder().decode(R.self, from: try await send(URLRequest(url: c.url!))).files.first { return f.id }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": Self.folderMime, "parents": [parent]])
        struct Created: Decodable { let id: String }
        return try JSONDecoder().decode(Created.self, from: try await send(req)).id
    }

    func download(_ id: String) async throws -> Data {
        try await send(URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!))
    }

    /// Creates (id nil) or replaces a file's content. Returns the file's metadata.
    func upload(_ data: Data, name: String, parent: String, id: String?) async throws -> DriveFile {
        let fields = "fields=id,name,md5Checksum,modifiedTime"
        var req: URLRequest
        if let id {
            req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media&\(fields)")!)
            req.httpMethod = "PATCH"
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
        } else {
            let boundary = "stagecharts-\(UUID().uuidString)"
            req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&\(fields)")!)
            req.httpMethod = "POST"
            req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
            body += try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])
            body += Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
            body += data
            body += Data("\r\n--\(boundary)--\r\n".utf8)
            req.httpBody = body
        }
        return try JSONDecoder().decode(DriveFile.self, from: try await send(req))
    }

    func trash(_ id: String) async throws {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"trashed":true}"#.utf8)
        _ = try await send(req)
    }
}

// MARK: - Sync engine

/// Two-way sync between the library folder and "StageCharts Library" in Google Drive.
/// Each file's MD5 at the last sync is remembered, so we know which side changed.
@MainActor
final class GoogleDriveSync: ObservableObject {
    @Published private(set) var status = "Not syncing"
    @Published private(set) var lastSync: Date?
    @Published private(set) var isSyncing = false
    @Published var lastError: String?

    let auth: GoogleAuth
    private let library: SongLibrary
    private var pending: Task<Void, Never>?
    private var timer: Timer?

    init(auth: GoogleAuth, library: SongLibrary) {
        self.auth = auth
        self.library = library
        library.onLocalChange = { [weak self] in self?.scheduleSync() }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleSync(after: 0) }
        }
    }

    /// Debounced sync after local edits (and on launch / foreground / timer).
    func scheduleSync(after delay: Double = 3) {
        guard auth.isSignedIn else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private struct State: Codable {
        var root: String?, songs: String?, pdf: String?, ink: String?, helix: String?
        var base: [String: String] = [:]     // path → MD5 when last in sync
        var ids: [String: String] = [:]      // path → Drive file id
    }

    private var stateURL: URL { library.base.appendingPathComponent(".google-drive-sync.json") }

    func syncNow() async {
        guard auth.isSignedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let api = DriveAPI(auth: auth)
            var state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State()
            status = "Connecting…"
            let root = try await api.folder(named: "StageCharts Library", in: "root")
            let songsDir = try await api.folder(named: "Songs", in: root)
            let pdfDir = try await api.folder(named: "PDF", in: songsDir)
            let inkDir = try await api.folder(named: "Ink", in: root)
            let helixDir = try await api.folder(named: "Helix", in: root)
            state.root = root; state.songs = songsDir; state.pdf = pdfDir; state.ink = inkDir; state.helix = helixDir

            // Remote listing by relative path.
            var remote: [String: DriveFile] = [:]
            for f in try await api.list(in: root) where ["song-settings.json", "setlists.json", RigMIDIMap.fileName].contains(f.name) { remote[f.name] = f }
            for f in try await api.list(in: songsDir) where f.md5Checksum != nil { remote["Songs/" + f.name] = f }
            for f in try await api.list(in: pdfDir) where f.md5Checksum != nil { remote["Songs/PDF/" + f.name] = f }
            for f in try await api.list(in: inkDir) where f.md5Checksum != nil { remote["Ink/" + f.name] = f }
            for f in try await api.list(in: helixDir) where f.md5Checksum != nil { remote["Helix/" + f.name] = f }

            // Local listing by relative path.
            let fm = FileManager.default
            var local: [String: URL] = [:]
            for name in ["song-settings.json", "setlists.json", RigMIDIMap.fileName] {
                let u = library.base.appendingPathComponent(name)
                if fm.fileExists(atPath: u.path) { local[name] = u }
            }
            for (dir, prefix) in [(library.folder, "Songs/"), (library.pdfFolder, "Songs/PDF/"), (library.inkFolder, "Ink/"), (library.helixFolder, "Helix/")] {
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
                    var isDir: ObjCBool = false
                    let u = dir.appendingPathComponent(name)
                    if fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue { local[prefix + name] = u }
                }
            }

            func parent(_ path: String) -> String {
                path.hasPrefix("Songs/PDF/") ? pdfDir : path.hasPrefix("Songs/") ? songsDir : path.hasPrefix("Ink/") ? inkDir : path.hasPrefix("Helix/") ? helixDir : root
            }
            func localURL(_ path: String) -> URL { library.base.appendingPathComponent(path) }

            let paths = Set(remote.keys).union(local.keys)
            var done = 0, changedLocally = false
            for path in paths.sorted() {
                done += 1
                if done % 10 == 0 { status = "Syncing \(done)/\(paths.count)…" }
                let lData = local[path].flatMap { SongLibrary.coordinatedData($0) }
                let L = lData.map(Self.md5), R = remote[path]?.md5Checksum, B = state.base[path]
                if L == R { if let L { state.base[path] = L; state.ids[path] = remote[path]?.id } else { state.base[path] = nil }; continue }

                if R == B {                                         // only local changed
                    if let lData {
                        let f = try await api.upload(lData, name: (path as NSString).lastPathComponent, parent: parent(path), id: remote[path]?.id)
                        state.ids[path] = f.id; state.base[path] = f.md5Checksum ?? L
                    } else if let id = remote[path]?.id {
                        try await api.trash(id); state.base[path] = nil; state.ids[path] = nil
                    }
                } else if L == B {                                  // only remote changed
                    if let r = remote[path] {
                        let data = try await api.download(r.id)
                        try fm.createDirectory(at: localURL(path).deletingLastPathComponent(), withIntermediateDirectories: true)
                        SongLibrary.coordinatedWrite(data, to: localURL(path))
                        state.base[path] = r.md5Checksum; state.ids[path] = r.id; changedLocally = true
                    } else {
                        try? fm.removeItem(at: localURL(path)); state.base[path] = nil; changedLocally = true
                    }
                } else {                                            // both changed (or first sync)
                    var rData: Data?
                    if let r = remote[path] { rData = try await api.download(r.id) }
                    let merged = Self.merge(path: path, local: lData, remote: rData,
                                            remoteNewer: Self.isRemoteNewer(remote[path], than: local[path]))
                    if merged != lData {
                        try fm.createDirectory(at: localURL(path).deletingLastPathComponent(), withIntermediateDirectories: true)
                        SongLibrary.coordinatedWrite(merged, to: localURL(path)); changedLocally = true
                    }
                    if merged != rData {
                        let f = try await api.upload(merged, name: (path as NSString).lastPathComponent, parent: parent(path), id: remote[path]?.id)
                        state.ids[path] = f.id; state.base[path] = f.md5Checksum ?? Self.md5(merged)
                    } else {
                        state.base[path] = Self.md5(merged); state.ids[path] = remote[path]?.id
                    }
                }
            }
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            if changedLocally { library.reloadAll() }
            lastSync = Date(); lastError = nil
            status = "Synced \(local.count > remote.count ? local.count : remote.count) files"
        } catch {
            lastError = error.localizedDescription
            status = "Sync failed"
        }
    }

    // MARK: Helpers

    static func md5(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private static func isRemoteNewer(_ r: DriveFile?, than l: URL?) -> Bool {
        guard let r, let t = r.modifiedTime, let rDate = ISO8601DateFormatter.withFraction.date(from: t) else { return false }
        guard let l, let lDate = (try? l.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return true }
        return rDate > lDate
    }

    /// Both sides changed: JSON files are merged entry by entry (newer side wins per entry);
    /// songs/documents: the newer file wins (a deleted side never deletes an edited one).
    static func merge(path: String, local: Data?, remote: Data?, remoteNewer: Bool) -> Data {
        guard let local else { return remote ?? Data() }
        guard let remote else { return local }
        if path == "song-settings.json",
           let l = try? JSONSerialization.jsonObject(with: local) as? [String: Any],
           let r = try? JSONSerialization.jsonObject(with: remote) as? [String: Any] {
            let m = remoteNewer ? l.merging(r) { _, b in b } : r.merging(l) { _, b in b }
            return (try? JSONSerialization.data(withJSONObject: m)) ?? local
        }
        if path == "setlists.json",
           let l = try? JSONSerialization.jsonObject(with: local) as? [[String: Any]],
           let r = try? JSONSerialization.jsonObject(with: remote) as? [[String: Any]] {
            var byID: [String: [String: Any]] = [:]
            for s in (remoteNewer ? l + r : r + l) { if let id = s["id"] as? String { byID[id] = s } }
            let sorted = byID.values.sorted { ($0["date"] as? String ?? "") > ($1["date"] as? String ?? "") }
            return (try? JSONSerialization.data(withJSONObject: sorted, options: [.prettyPrinted])) ?? local
        }
        return remoteNewer ? remote : local
    }
}

private extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}
