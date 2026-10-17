import CryptoKit
import Foundation

/// The files a DDI mount needs, kept on disk.
///
/// Which files depends on the OS: iOS 16 mounts the legacy, per-version
/// DeveloperDiskImage.dmg with its signature; iOS 17 – 26.3 mount the
/// personalized image through the image mounter; from iOS 26.4 the DDI is a
/// cryptex, installed through cryptexd from a different set of files. Each set
/// lives in its own directory, so an OS update that crosses a boundary (or, on
/// iOS 16, any minor version) downloads the other set instead of mounting
/// files the device no longer accepts.
///
/// Not bundled in the app: the images change with Xcode releases, and most
/// users mounting a DDI already have network. Downloaded once and reused — the
/// mount itself is what needs to be repeated after a reboot, not the download.
@MainActor
final class DeveloperDiskImageStore: ObservableObject {

    enum MountMethod: String {
        /// iOS 16: image mounter over a lockdownd session, legacy image +
        /// signature. One image per OS minor version, not personalized.
        case legacy
        /// iOS 17 – 26.3: image mounter, personalized image.
        case personalized
        /// iOS 26.4 and later: cryptexd installs the DDI cryptex.
        case cryptex

        /// Folder in the upstream repository, maintained by the pymobiledevice3 author. Apple does
        /// not publish these for direct download; the same content ships inside
        /// Xcode, so a user with a Mac can supply their own copy instead (see
        /// `importComponent`). For iOS 16 that is
        /// `Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport/16.x/`
        /// of an Xcode 14.
        var mirrorFolder: String {
            switch self {
            case .legacy: return "DeveloperDiskImages/\(DeveloperDiskImageStore.legacyImageVersion)"
            case .personalized: return "PersonalizedImages/Xcode_iOS_DDI_Personalized"
            case .cryptex: return "PersonalizedImages/Xcode_iOS_DDI_Cryptex"
            }
        }

        /// Directory name under Application Support/DDI. The personalized and
        /// cryptex names predate the legacy set and are kept as they were.
        var localFolder: String {
            switch self {
            case .legacy: return "Legacy-\(DeveloperDiskImageStore.legacyImageVersion)"
            case .personalized: return "Xcode_iOS_DDI_Personalized"
            case .cryptex: return "Xcode_iOS_DDI_Cryptex"
            }
        }

        /// SHA-256 of each file at `pinnedCommit`.
        var sha256: [Component: String] {
            switch self {
            case .legacy:
                // 16.2/16.3 and 16.4/16.6/16.7 share one image upstream.
                let pins: [String: (image: String, signature: String)] = [
                    "16.0": ("429d2d05b7c9093f214b117a26571fa7d9596c5ff03e7983b70caff743f0afb1",
                             "d30ae9c12874254c5cb453abb7c412c6796913e5533de6b68f1b28f435981100"),
                    "16.1": ("086bf1c1a278615e60dd5ce2d2ff55a21996bbdef3dc67df20e209e7dcd48558",
                             "54b0ad8113231b1e11faebfdae4b347b482ed12dbe8caf155d25b17e74b1a60e"),
                    "16.2": ("d30f6d1274e1300910cd22c1104136006f0c55e28110b16cf20ed1ec48fad0e5",
                             "247aa8dd50dea880437a1fabfda21552971f88d39384aca6f13d2c0eba7bdac0"),
                    "16.3": ("d30f6d1274e1300910cd22c1104136006f0c55e28110b16cf20ed1ec48fad0e5",
                             "247aa8dd50dea880437a1fabfda21552971f88d39384aca6f13d2c0eba7bdac0"),
                    "16.4": ("6e4449ff8c751b4432934ade838382c79330b096b865eebabbc1fa42ead9c185",
                             "4e82ee8aa75c5ecdd320e075b7d9e4ea2fc1915d0bb776007e8dbc5728ca5d86"),
                    "16.5": ("99fcf9a7300ab2504a2b9a79f210702f2f6d6eb056053fc8517b80a6a3e18a16",
                             "355169a9753c23fff95f6ebc1e39a433f653a9e0e059580642d92629c1ac0071"),
                    "16.6": ("6e4449ff8c751b4432934ade838382c79330b096b865eebabbc1fa42ead9c185",
                             "4e82ee8aa75c5ecdd320e075b7d9e4ea2fc1915d0bb776007e8dbc5728ca5d86"),
                    "16.7": ("6e4449ff8c751b4432934ade838382c79330b096b865eebabbc1fa42ead9c185",
                             "4e82ee8aa75c5ecdd320e075b7d9e4ea2fc1915d0bb776007e8dbc5728ca5d86"),
                ]
                guard let pin = pins[DeveloperDiskImageStore.legacyImageVersion] else { return [:] }
                return [.legacyImage: pin.image, .legacySignature: pin.signature]
            case .personalized: return [
                .buildManifest: "8edd4a2f4f4ef1fbd7bfe49785d8badc673d1395d1d94d85b132ca8ab5ecaf54",
                .image: "05fd807da5e19f030fa4941f24800c965c6c77982ab572dd5d1ef778fb69f9ca",
                .trustCache: "36af60889ff5a737874a26daeb8e1a0139ebfebec6ec2e4d8f6a3c1bf1dce35c",
            ]
            case .cryptex: return [
                .buildManifest: "27385d7582b03b36bb3104e22b520aee0c47d72fecb4e8ecfe12ef5d966c7012",
                .image: "873097f695a8b9734e2abc54f795a8874d40ff6fd11208ecb01ef29534c7c176",
                .trustCache: "f7f21986074eee03a215aca16ecfc78d6bf183600d8a0d2fb691f9896782e6f0",
                .cryptexInfo: "edf49aef55aacc063d4d7be05b713bb545ce2993b3f62bcc15eccd75e610ee6c",
                .rootHash: "3543fad2805b88119695c417e12679380b3b5a2742994bbcc839c8e2de5d7302",
            ]
            }
        }

        var components: [Component] {
            switch self {
            case .legacy: return [.legacyImage, .legacySignature]
            case .personalized: return [.buildManifest, .image, .trustCache]
            case .cryptex: return [.buildManifest, .image, .trustCache, .cryptexInfo, .rootHash]
            }
        }
    }

    /// The method this device's OS needs.
    nonisolated static var mountMethod: MountMethod {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion < 17 { return .legacy }
        return v.majorVersion > 26 || (v.majorVersion == 26 && v.minorVersion >= 4) ? .cryptex : .personalized
    }

    /// The mirror's folder for this OS's legacy image: `major.minor`, the way
    /// Xcode's DeviceSupport names them (patch releases share one image). The
    /// mirror stops at 16.7 — the last iOS 16 minor — so anything later in
    /// the 16 line is clamped to it rather than pointing at a missing folder.
    nonisolated static var legacyImageVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let minor = v.majorVersion == 16 ? min(v.minorVersion, 7) : v.minorVersion
        return "\(v.majorVersion).\(minor)"
    }

    // MARK: - Download sources

    /// One place the image files can be fetched from. `base` is laid out like
    /// the upstream repository's root: `PersonalizedImages/Xcode_iOS_DDI_*/`
    /// and `DeveloperDiskImages/16.x/` (see `MountMethod.mirrorFolder`).
    struct Source {
        let name: String
        let base: String

        func url(for component: Component, method: MountMethod) -> URL? {
            URL(string: "\(base)/\(method.mirrorFolder)/\(component.rawValue)")
        }
    }

    /// The upstream commit the files and their SHA-256s below are pinned to.
    /// Both public sources are addressed by this commit, never by a branch,
    /// so what they serve can't change under the checksums. To move to a
    /// newer image: bump this, re-hash every file (`shasum -a 256`), update
    /// `MountMethod.sha256`, and re-upload to any CDN listed in Info.plist.
    static let pinnedCommit = "6eae353ae694bda1c421d4a3eee5459ae59c99a1"

    /// Tried in order until one serves a file whose SHA-256 matches.
    ///
    /// Our own mirrors go first: Info.plist `LoopCtrlDDIMirrors`, an array of
    /// base URLs (set in project.yml), each hosting the pinned files under the
    /// same layout. Then jsDelivr, a CDN in front of GitHub that is reachable
    /// from more networks (mainland China included) than raw.githubusercontent.com,
    /// and GitHub itself last. A mirror can't hand out a tampered image: every
    /// file is checked against the pinned hash wherever it came from.
    static var sources: [Source] {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "LoopCtrlDDIMirrors") as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("https://") }
            .map { Source(name: URL(string: $0)?.host ?? $0, base: $0.hasSuffix("/") ? String($0.dropLast()) : $0) }
        return configured + [
            Source(name: "jsDelivr",
                   base: "https://cdn.jsdelivr.net/gh/doronz88/DeveloperDiskImage@\(pinnedCommit)"),
            Source(name: "GitHub",
                   base: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/\(pinnedCommit)"),
        ]
    }

    enum Component: String, CaseIterable {
        case buildManifest = "BuildManifest.plist"
        case image = "Image.dmg"
        case trustCache = "Image.dmg.trustcache"
        case cryptexInfo = "Image.dmg.cryptex_info"
        case rootHash = "Image.dmg.root_hash"
        case legacyImage = "DeveloperDiskImage.dmg"
        case legacySignature = "DeveloperDiskImage.dmg.signature"

        /// Share of the download, for a progress bar that moves with the bytes.
        var weight: Double {
            switch self {
            case .image, .legacyImage: return 0.9
            case .buildManifest: return 0.07
            default: return 0.01
            }
        }
    }

    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage: String?

    private nonisolated static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DDI")
    }

    /// This device's file set. Builds before the cryptex split kept the
    /// personalized files directly in `DDI/`; they are moved into place
    /// rather than downloaded again.
    nonisolated static var directory: URL {
        let dir = rootDirectory.appendingPathComponent(mountMethod.localFolder)
        migrateLegacyFiles(into: dir)
        return dir
    }

    private nonisolated static func migrateLegacyFiles(into dir: URL) {
        guard mountMethod == .personalized else { return }
        let fm = FileManager.default
        for c in MountMethod.personalized.components {
            let old = rootDirectory.appendingPathComponent(c.rawValue)
            guard fm.fileExists(atPath: old.path) else { continue }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let new = dir.appendingPathComponent(c.rawValue)
            if fm.fileExists(atPath: new.path) { try? fm.removeItem(at: old) } else { try? fm.moveItem(at: old, to: new) }
        }
    }

    nonisolated static func url(for component: Component) -> URL {
        directory.appendingPathComponent(component.rawValue)
    }

    /// True when every file of this device's set is present. Deliberately does
    /// not validate their contents — a corrupt image surfaces as a mount error,
    /// and guessing at validity here would just add a second place to be wrong.
    static var isComplete: Bool {
        mountMethod.components.allSatisfy {
            FileManager.default.fileExists(atPath: url(for: $0).path)
        }
    }

    static var totalBytesOnDisk: Int64 {
        mountMethod.components.reduce(0) { sum, c in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: c).path)
            return sum + ((attrs?[.size] as? Int64) ?? 0)
        }
    }

    func download() async throws {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        defer { isDownloading = false }

        try FileManager.default.createDirectory(at: Self.directory,
                                                withIntermediateDirectories: true)

        // Weight by size so the bar reflects reality: the image dwarfs the
        // rest, and an evenly-weighted bar would sit near the end for the
        // whole download.
        let components = Self.mountMethod.components
        let total = components.reduce(0) { $0 + $1.weight }
        var completed = 0.0

        for component in components {
            let dest = Self.url(for: component)
            let weight = component.weight / total
            if FileManager.default.fileExists(atPath: dest.path) {
                completed += weight
                progress = completed
                continue
            }
            try await download(component, to: dest) { [weak self] frac in
                Task { @MainActor in self?.progress = completed + frac * weight }
            }
            completed += weight
            progress = completed
        }
        statusMessage = nil
    }

    /// Generous limits: a source can crawl and stall for long stretches on
    /// some networks, and the default 60s idle limit then fails the image
    /// partway.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()
    /// Per source, before moving on to the next one.
    private static let downloadAttempts = 3

    /// Download one file from the first source that serves it intact: an
    /// HTTP error, a connection that keeps dropping, or a file whose SHA-256
    /// doesn't match moves on to the next source.
    private func download(_ component: Component, to dest: URL,
                          onProgress: @escaping (Double) -> Void) async throws {
        let method = Self.mountMethod
        let expectedHash = method.sha256[component]
        var lastError: Error = DDIError.downloadFailed(component.rawValue, "no download source")
        for source in Self.sources {
            guard let url = source.url(for: component, method: method) else { continue }
            do {
                let data = try await download(component, from: url, sourceName: source.name, onProgress: onProgress)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if let expectedHash, hash != expectedHash {
                    loopctrlLog("⚠️ \(component.rawValue) from \(source.name): SHA-256 \(hash) ≠ pinned \(expectedHash)")
                    lastError = DDIError.downloadFailed(component.rawValue, "checksum mismatch from \(source.name)")
                    onProgress(0)
                    continue
                }
                try data.write(to: dest, options: .atomic)
                loopctrlLog("Downloaded \(component.rawValue) from \(source.name) — \(data.count)B, SHA-256 ok")
                onProgress(1.0)
                return
            } catch {
                lastError = error
                loopctrlLog("⚠️ \(component.rawValue) from \(source.name) failed: \(error.localizedDescription)")
                onProgress(0)
            }
        }
        throw lastError
    }

    /// Fetch one file from one source, resuming from what already arrived
    /// when the connection drops (a Range request; a server that ignores it
    /// sends the whole file again, and the partial copy is discarded).
    private func download(_ component: Component, from url: URL, sourceName: String,
                          onProgress: @escaping (Double) -> Void) async throws -> Data {
        var data = Data()
        var expected: Int64 = -1
        var lastError: Error?
        statusMessage = "Downloading \(component.rawValue) from \(sourceName)…"
        for attempt in 1...Self.downloadAttempts {
            do {
                var request = URLRequest(url: url)
                if !data.isEmpty { request.setValue("bytes=\(data.count)-", forHTTPHeaderField: "Range") }
                let (bytes, response) = try await Self.session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
                    throw DDIError.downloadFailed(component.rawValue,
                        (response as? HTTPURLResponse).map { "HTTP \($0.statusCode) from \(sourceName)" } ?? "no response from \(sourceName)")
                }
                if http.statusCode == 200 {
                    data = Data()
                    expected = response.expectedContentLength
                } else if expected < 0, response.expectedContentLength > 0 {
                    expected = Int64(data.count) + response.expectedContentLength
                }
                if expected > 0 { data.reserveCapacity(Int(expected)) }

                var lastReport = 0.0
                for try await byte in bytes {
                    data.append(byte)
                    if expected > 0 {
                        let frac = Double(data.count) / Double(expected)
                        // Reporting every byte would flood the main actor; 1% is
                        // plenty for a progress bar.
                        if frac - lastReport >= 0.01 {
                            lastReport = frac
                            onProgress(frac)
                        }
                    }
                }
                if attempt > 1 { loopctrlLog("\(component.rawValue) from \(sourceName) finished on attempt \(attempt)") }
                return data
            } catch let error as DDIError {
                throw error   // an HTTP error won't fix itself; try the next source
            } catch {
                lastError = error
                loopctrlLog("⚠️ \(component.rawValue) from \(sourceName) interrupted at \(data.count)B (attempt \(attempt)): \(error.localizedDescription)")
                statusMessage = "Downloading \(component.rawValue) from \(sourceName)… (retrying, \(attempt)/\(Self.downloadAttempts - 1))"
            }
        }
        throw lastError ?? DDIError.downloadFailed(component.rawValue, "no response from \(sourceName)")
    }

    /// Accept a user-supplied copy, for people who'd rather pull the files out
    /// of their own Xcode than trust a third-party mirror.
    static func importComponent(_ component: Component, from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: url)
        try data.write(to: self.url(for: component), options: .atomic)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
