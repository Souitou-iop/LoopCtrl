import Foundation

/// Transforms for the `observe` attachment on action replies.
enum ObserveFormat {
    /// The compact form of a rendered tree: same nodes in the same order, with
    /// the coordinate frames stripped. Ref-based flows re-resolve geometry on
    /// the device at tap time, so frames are the one thing an attachment can
    /// lose safely; what remains (type, label, id, value) is what find_element
    /// matches on. Measured on a 132-node Settings page: 9.7KB → 3.2KB.
    static func compact(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            var t = String(line.drop(while: { $0 == " " }))
            // The frame is always the trailing ", {{x, y}, {w, h}}"; a label or
            // value could itself contain "{{", so cut from the LAST occurrence.
            if let frame = t.range(of: ", {{", options: .backwards), t[frame.upperBound...].contains("}}") {
                t = String(t[..<frame.lowerBound])
            }
            return t
        }.joined(separator: "\n")
    }
}
