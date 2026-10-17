import Foundation
import IDevice
import UniformTypeIdentifiers

/// Where the device pairing record lives.
///
/// Which record a mount needs depends on the OS, the same split as
/// `DeveloperDiskImageStore.MountMethod`:
///
/// **iOS 17+** — a RemotePairing (RP) record: a plist with the host's Ed25519
/// keys (`public_key`, `private_key`) and its `identifier`, which the mount
/// uses to open the RemotePairing tunnel to this device's `remoted`. Two
/// sources produce one without a separate lockdown step:
///  * a computer pairing, or LoopCtrl's own on-device pairing (iOS 27+) — RP keys only.
///  * iLoader on iOS 17.4+ — a merged plist carrying both the lockdown record
///    (`HostID`, `HostCertificate`, …) and the RP keys.
/// A lockdown-only record has no RP keys and cannot open the tunnel, so on
/// these systems it is turned away at import.
///
/// **iOS 16** — a lockdown pairing record (`HostID`, `SystemBUID`,
/// `HostCertificate`, `HostPrivateKey`, `RootCertificate`, `RootPrivateKey`,
/// `DeviceCertificate`, `WiFiMACAddress`, usually `EscrowBag`/`UDID`): what
/// `idevicepair pair`, jitterbugpair or iLoader write, and what SideStore
/// imports. There is no `remoted` to talk to; the mount opens a lockdownd
/// session with it instead. A merged file works here too.
///
/// Only its *path* matters to the mounting code — the plist is parsed by the
/// idevice library, never here.
enum PairingFileStore {

    /// Types the import picker accepts.
    ///
    /// `.fileImporter` matches a picked file's type against this list, and the
    /// match has to hold for the file's *actual* UTI. A pairing record is an
    /// XML property list, which iOS types as `public.xml` — a sibling of
    /// `public.data`, not a subtype, so `.data` alone does not let it through.
    ///
    /// Two traps made the old list miss real files:
    ///  * `UTType(filenameExtension:)` returns nil for `plist` /
    ///    `mobiledevicepairing` on iOS — no such UTI is registered — so those
    ///    entries silently vanished and the list collapsed to `.data`.
    ///  * A picker only enables what the list *contains*; `.xml` has to be
    ///    listed on its own because it is not covered by `.data`.
    ///
    /// So declare every type explicitly with `UTType(tag:tagClass:conformingTo:)`
    /// (which does not depend on a system-registered UTI) and keep `.data` last
    /// as the permissive catch-all. The file is validated after the pick anyway,
    /// so a wider list costs nothing but a clearer failure.
    static let supportedContentTypes: [UTType] = {
        var types: [UTType] = []

        // The standard property-list type (both XML and binary forms).
        types.append(.propertyList)
        // A pairing record is usually XML: iOS reports `public.xml`, and the
        // picker must be told about it explicitly.
        types.append(.xml)

        // Apple's tooling and the community write these extensions. Build the
        // types from their tags rather than by filename lookup, so they exist
        // even where the system has no UTI registered for the extension.
        for ext in ["mobiledevicepairing", "mobiledevicepair"] {
            if let t = UTType(tag: ext, tagClass: .filenameExtension,
                              conformingTo: .propertyList) {
                types.append(t)
            }
        }
        // A plain `.plist` extension, in case the file keeps it.
        if let t = UTType(tag: "plist", tagClass: .filenameExtension,
                          conformingTo: .propertyList) {
            types.append(t)
        }

        // Permissive catch-all: every file conforms to `.data`, so this keeps
        // the picker from greying out a record saved under an unexpected
        // extension. Content is validated by `validate(_:)` after import.
        types.append(.data)

        return types
    }()

    /// Application Support/Pairing/pairingFile.plist — outside Documents so it
    /// isn't casually deleted from the Files app, since losing it means
    /// re-pairing from a Mac.
    static var storedURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Pairing/pairingFile.plist")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: storedURL.path)
    }

    /// When the current file was imported — shown in the UI so a stale pairing
    /// file (a common cause of confusing mount failures) is at least visible.
    static var importedAt: Date? {
        try? FileManager.default.attributesOfItem(atPath: storedURL.path)[.modificationDate] as? Date
    }

    /// Copy a user-picked file into place.
    ///
    /// The picker hands back a security-scoped URL that is only readable inside
    /// a start/stop pair, so the bytes are copied out immediately rather than
    /// holding the URL.
    static func importFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        try store(Data(contentsOf: url))
    }

    /// Validate a pairing record and write it into place, replacing any
    /// earlier one. Used by both import and on-device pairing.
    static func store(_ data: Data) throws {
        try validate(data)

        let dest = storedURL
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // 0600 from the start: this file authenticates as a trusted host to the
        // device, so it deserves the same care as a private key.
        try data.write(to: dest, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: dest.path)
        loopctrlLog("Pairing file stored (\(data.count)B)")
    }

    /// Posted after a pairing file is stored, so a screen showing the old
    /// state can refresh.
    static let didImport = Notification.Name("PairingFileStore.didImport")

    /// Store a file shared to the app ("Open in LoopCtrl"). iOS hands over a copy
    /// in an inbox folder of ours (Documents/Inbox, or tmp/<bundle id>-Inbox
    /// on newer systems), which is removed afterwards whatever the outcome.
    static func importShared(from url: URL) throws {
        defer {
            if url.deletingLastPathComponent().lastPathComponent.hasSuffix("Inbox") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try importFile(from: url)
        NotificationCenter.default.post(name: didImport, object: nil)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: storedURL)
    }

    /// Reject anything that clearly isn't a pairing record, so the failure lands
    /// at import time with a clear message instead of surfacing later as an
    /// opaque error from deep inside the mount.
    ///
    /// The check mirrors what idevice's `RpPairingFile::from_bytes` requires:
    /// 32-byte `public_key` and `private_key`, and a string `identifier`. Any
    /// other keys (a merged iLoader file's lockdown half) are left alone.
    /// On iOS 16 the lockdown half is what counts; see `validateLockdown`.
    private static func validate(_ data: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else {
            throw DDIError.invalidPairingFile("Not a property list. Expected a "
                + "pairing file from a computer pairing, or from iLoader on iOS 17.4 or later.")
        }
        if DeveloperDiskImageStore.mountMethod == .legacy {
            try validateLockdown(plist, data: data)
            return
        }
        let hasKeys = ["public_key", "private_key"].allSatisfy { (plist[$0] as? Data)?.count == 32 }
        guard hasKeys, plist["identifier"] is String else {
            if plist["HostID"] != nil {
                throw DDIError.invalidPairingFile(
                    "This is a lockdown-only pairing record (from `idevicepair` or an "
                    + "older iLoader). Mounting needs a RemotePairing record: pair on "
                    + "this device (iOS 27+), or export again with iLoader on iOS 17.4+.")
            }
            throw DDIError.invalidPairingFile(
                "No RemotePairing keys (public_key, private_key, identifier). This "
                + "looks like a property list but not a pairing record.")
        }
    }

    /// iOS 16: the record has to be a lockdown pairing record, and idevice has
    /// to be able to load it. The key check is only there for a readable
    /// message; idevice's own parse (`PairingFile::from_bytes`, which also
    /// decodes the certificates and key) is the authority.
    private static func validateLockdown(_ plist: [String: Any], data: Data) throws {
        let required = ["HostID", "SystemBUID", "HostCertificate", "HostPrivateKey",
                        "RootCertificate", "RootPrivateKey", "DeviceCertificate", "WiFiMACAddress"]
        let missing = required.filter { plist[$0] == nil }
        guard missing.isEmpty else {
            if plist["public_key"] != nil {
                throw DDIError.invalidPairingFile(
                    "This is a RemotePairing record, which iOS 16 has no use for. iOS 16 "
                    + "needs a lockdown pairing record — from `idevicepair pair`, "
                    + "jitterbugpair or iLoader on a computer.")
            }
            throw DDIError.invalidPairingFile(
                "Not a lockdown pairing record — missing \(missing.joined(separator: ", ")).")
        }
        var handle: OpaquePointer?
        let err = data.withUnsafeBytes { buf in
            idevice_pairing_file_from_bytes(buf.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), &handle)
        }
        if let handle { idevice_pairing_file_free(handle) }
        if let err {
            let message = err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
            idevice_error_free(err)
            throw DDIError.invalidPairingFile("The lockdown pairing record can't be loaded: \(message)")
        }
    }
}
