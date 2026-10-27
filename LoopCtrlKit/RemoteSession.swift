import Foundation

/// Who is watching and driving the phone right now, what each of them did,
/// and whether its owner has paused remote control (docs/remote-control.md,
/// "Control").
///
/// Several people and agents may drive at once. Each counts as operating for
/// a while after their last action (people 60 s, agents 30 s) and as present
/// while they also watch the screen, and each keeps a log of their own
/// actions with what became of them.
///
/// The owner's pause, from the phone, stops everything remote: no frames, no
/// reads of the screen, no actions, until they resume.
final class RemoteSession {
    static let shared = RemoteSession()

    enum Kind: String { case person, agent }

    struct Action: Equatable {
        let id: Int
        let at: Date
        let method: String
        let detail: String
        var outcome: String
    }

    struct Participant: Equatable {
        let tok: String
        var name: String
        var kind: Kind
        /// Screen streams this client has open.
        var watching = 0
        var firstAction: Date?
        var lastAction: Date?
        var actions = 0
        var log: [Action] = []
    }

    static let personIdle: TimeInterval = 60
    static let agentIdle: TimeInterval = 30
    /// Actions kept per participant, newest last.
    static let logLimit = 500

    /// Called (off the lock, on any thread) when who is present, who is
    /// operating, or the pause changes; not on every action.
    var onChange: (() -> Void)?
    /// Each finished action as one line, with who did it, for the runner's log.
    var onLog: ((String) -> Void)?

    private let lock = NSLock()
    private var people: [String: Participant] = [:]
    private var order: [String] = []
    private var nextID = 1
    private var isPaused = false
    private var signature = ""

    private static func idle(_ kind: Kind) -> TimeInterval {
        kind == .person ? personIdle : agentIdle
    }

    private static func operating(_ p: Participant, _ now: Date) -> Bool {
        guard let last = p.lastAction else { return false }
        return now.timeIntervalSince(last) <= idle(p.kind)
    }

    private static func present(_ p: Participant, _ now: Date) -> Bool {
        p.watching > 0 || operating(p, now)
    }

    private func entryLocked(_ tok: String, name: String, kind: Kind) -> Participant {
        if let p = people[tok] {
            return p
        }
        order.append(tok)
        return Participant(tok: tok, name: name, kind: kind)
    }

    /// Whether the visible state moved since the last call: run under the
    /// lock, after a change, to decide whether to call `onChange`.
    private func changedLocked(_ now: Date) -> Bool {
        var parts = [isPaused ? "P" : "-"]
        for tok in order {
            guard let p = people[tok], Self.present(p, now) else { continue }
            parts.append("\(tok):\(p.kind.rawValue):\(p.watching > 0 ? "w" : "")\(Self.operating(p, now) ? "o" : "")")
        }
        let next = parts.joined(separator: ",")
        guard next != signature else { return false }
        signature = next
        return true
    }

    private func notify(_ changed: Bool) {
        if changed { onChange?() }
    }

    // MARK: - Actions

    /// Note an action from `tok` before it runs. Returns its id for `finish`.
    @discardableResult
    func begin(tok: String, name: String, kind: Kind, method: String, detail: String,
               now: Date = Date()) -> Int {
        lock.lock()
        var p = entryLocked(tok, name: name, kind: kind)
        p.name = name
        p.kind = kind
        if !Self.operating(p, now) { p.firstAction = now }
        p.lastAction = now
        p.actions += 1
        let id = nextID
        nextID += 1
        p.log.append(Action(id: id, at: now, method: method, detail: detail, outcome: "sent"))
        if p.log.count > Self.logLimit { p.log.removeFirst(p.log.count - Self.logLimit) }
        people[tok] = p
        let changed = changedLocked(now)
        lock.unlock()
        notify(changed)
        return id
    }

    /// What became of action `id`: applied, failed, queued or unknown.
    func finish(tok: String, id: Int, outcome: String) {
        lock.lock()
        guard var p = people[tok], let i = p.log.lastIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        p.log[i].outcome = outcome
        people[tok] = p
        let a = p.log[i]
        let who = (p.kind == .agent ? "agent " : "") + p.name
        lock.unlock()
        onLog?("👤 \(who): \(a.method)\(a.detail.isEmpty ? "" : " " + a.detail) → \(outcome)")
    }

    // MARK: - Watching

    /// A screen stream opened for `tok`.
    func watch(tok: String, name: String, now: Date = Date()) {
        lock.lock()
        var p = entryLocked(tok, name: name, kind: .person)
        p.watching += 1
        people[tok] = p
        let changed = changedLocked(now)
        lock.unlock()
        notify(changed)
    }

    func unwatch(tok: String, now: Date = Date()) {
        lock.lock()
        if var p = people[tok] {
            p.watching = max(0, p.watching - 1)
            people[tok] = p
        }
        let changed = changedLocked(now)
        lock.unlock()
        notify(changed)
    }

    /// `tok` stops counting as operating (it still shows while it watches).
    func release(tok: String, now: Date = Date()) {
        lock.lock()
        people[tok]?.lastAction = nil
        let changed = changedLocked(now)
        lock.unlock()
        notify(changed)
    }

    /// Look again: operators lapse quietly, nobody calls when they stop.
    /// The runner calls this every few seconds while anyone is present.
    func sweep(now: Date = Date()) {
        lock.lock()
        let changed = changedLocked(now)
        lock.unlock()
        notify(changed)
    }

    // MARK: - Pause

    /// The owner pauses (or resumes) everything remote. Pausing also ends
    /// everyone's operating spell.
    func setPaused(_ paused: Bool, now: Date = Date()) {
        lock.lock()
        isPaused = paused
        if paused {
            for tok in order { people[tok]?.lastAction = nil }
        }
        let changed = changedLocked(now)
        lock.unlock()
        notify(changed)
    }

    var paused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPaused
    }

    // MARK: - Reading

    /// Everyone watching or operating now, in the order they first came.
    func present(now: Date = Date()) -> [(participant: Participant, operating: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { tok in
            guard let p = people[tok], Self.present(p, now) else { return nil }
            return (p, Self.operating(p, now))
        }
    }

    /// The state as clients see it (the `control` RPC and the stream's STATE
    /// message): `{paused, people: [{tok, name, kind, watching, operating,
    /// since, actions}]}`.
    func state(now: Date = Date()) -> [String: JSONValue] {
        let list = present(now: now).map { entry -> JSONValue in
            let p = entry.participant
            var o: [String: JSONValue] = [
                "tok": .string(p.tok), "name": .string(p.name), "kind": .string(p.kind.rawValue),
                "watching": .bool(p.watching > 0), "operating": .bool(entry.operating), "actions": .int(p.actions),
            ]
            if entry.operating, let since = p.firstAction { o["since"] = .int(Int(since.timeIntervalSince1970)) }
            return .object(o)
        }
        return ["paused": .bool(paused), "people": .array(list)]
    }

    /// Each participant's own actions since the runner started, oldest first:
    /// `[{tok, name, kind, actions: [{at, method, detail, outcome}]}]`. Only
    /// `tok`'s when given.
    func logs(tok: String? = nil, limit: Int = logLimit) -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { t -> JSONValue? in
            guard tok == nil || tok == t, let p = people[t], !p.log.isEmpty else { return nil }
            return .object([
                "tok": .string(p.tok), "name": .string(p.name), "kind": .string(p.kind.rawValue),
                "actions": .array(p.log.suffix(max(1, limit)).map { a in .object([
                    "at": .double((a.at.timeIntervalSince1970 * 1000).rounded() / 1000),
                    "method": .string(a.method), "detail": .string(a.detail), "outcome": .string(a.outcome),
                ]) }),
            ])
        }
    }

    /// Methods that still answer while the owner has paused remote control:
    /// enough to show the pause and to administer the device, nothing that
    /// reads or touches the screen.
    static let allowedWhilePaused: Set<String> = [
        "control", "device_info", "logs", "config", "stream_ack", "stream_ticket", "is_locked", "wait",
    ]

    /// A short, non-sensitive description of an action for the logs: where
    /// it touched, never what was typed.
    static func describe(_ method: String, _ params: [String: JSONValue]?) -> String {
        let p = params ?? [:]
        func n(_ k: String) -> String? { p[k]?.doubleValue.map { String(Int($0.rounded())) } }
        func at(_ x: String, _ y: String) -> String? {
            guard let a = n(x), let b = n(y) else { return nil }
            return "(\(a), \(b))"
        }
        switch method {
        case "tap", "double_tap":
            return at("x", "y") ?? p["ref"]?.stringValue ?? ""
        case "long_press":
            return [at("x", "y"), p["duration"]?.doubleValue.map { String(format: "%.1fs", $0) }]
                .compactMap { $0 }.joined(separator: " ")
        case "drag":
            guard let a = at("from_x", "from_y"), let b = at("to_x", "to_y") else { return "" }
            return "\(a) → \(b)"
        case "gesture":
            guard case .array(let f)? = p["fingers"] else { return "" }
            return "\(f.count) finger\(f.count == 1 ? "" : "s")"
        case "type":
            let count = p["text"]?.stringValue?.count ?? 0
            return "\(count) character\(count == 1 ? "" : "s")"
        case "launch_app", "activate_app", "terminate_app":
            return p["bundle_id"]?.stringValue ?? p["name"]?.stringValue ?? ""
        case "rotate":
            return p["orientation"]?.stringValue ?? ""
        case "swipe", "scroll", "page":
            return p["direction"]?.stringValue ?? ""
        default:
            return ""
        }
    }
}
