import SwiftUI
import UIKit

/// The few visual building blocks the home screen is made of. Liquid Glass on
/// iOS 26 and later, the closest stock equivalent before that (the app still
/// deploys to iOS 16).
extension View {
    /// A rounded panel behind grouped content, e.g. the status card.
    @ViewBuilder func card(cornerRadius: CGFloat = 20) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// The one prominent action on a screen.
    @ViewBuilder func primaryAction(_ tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(tint).controlSize(.large)
        } else {
            self.buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
        }
    }
}

/// This app's own icon, read back from the bundle; an SF Symbol stand-in when
/// the system doesn't hand it out (it's an Icon Composer icon, which not every
/// iOS version exposes through `UIImage(named:)`).
struct AppIconImage: View {
    var size: CGFloat = 112

    private static let image: UIImage? = {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        var names = (primary?["CFBundleIconFiles"] as? [String] ?? []).reversed().map { $0 }
        if let name = primary?["CFBundleIconName"] as? String { names.append(name) }
        names.append("AppIcon")
        for name in names {
            if let image = UIImage(named: name) { return image }
        }
        return nil
    }()

    var body: some View {
        if let image = Self.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [.accentColor.opacity(0.85), .accentColor],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundColor(.white)
                )
        }
    }
}
