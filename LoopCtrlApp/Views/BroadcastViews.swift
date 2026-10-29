import ReplayKit
import SwiftUI
import UIKit

/// The system broadcast (docs/remote-control.md, "System broadcast"): the
/// switch in Settings, and the row on the home card that starts and stops it.
/// iOS starts a broadcast only from its own picker button, so the row presses
/// one that is kept out of sight and limited to LoopCtrl's extension.
enum SystemBroadcast {
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: InProcessRunnerControl.broadcastKey)
    }

    /// Tell the runner (same process) to take the broadcast, or not.
    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: InProcessRunnerControl.broadcastKey)
        NotificationCenter.default.post(name: InProcessRunnerControl.setBroadcast, object: nil, userInfo: ["on": on])
    }

    static var extensionID: String? {
        Bundle.main.bundleIdentifier.map { $0 + ".broadcast" }
    }
}

/// Home card row: the broadcast's state, and a tap that starts or stops it.
struct BroadcastRow: View {
    @State private var captured = UIScreen.main.isCaptured
    @State private var picker = BroadcastPicker()

    var body: some View {
        Button { picker.press() } label: {
            HStack {
                Text(L10n.ui(.broadcastToggle)).foregroundColor(.primary)
                Spacer()
                if captured {
                    Label(L10n.ui(.broadcastRunning), systemImage: "record.circle")
                        .foregroundColor(.red)
                } else {
                    Text(L10n.ui(.broadcastStart)).foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(picker.frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false))
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captured = UIScreen.main.isCaptured
        }
    }
}

/// The system's broadcast picker, pressed from code.
struct BroadcastPicker: UIViewRepresentable {
    private let view: RPSystemBroadcastPickerView = {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        v.preferredExtension = SystemBroadcast.extensionID
        v.showsMicrophoneButton = false
        return v
    }()

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView { view }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}

    func press() {
        for case let button as UIButton in view.subviews {
            button.sendActions(for: .touchUpInside)
        }
    }
}
