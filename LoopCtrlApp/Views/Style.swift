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

    /// A compact capsule that floats over scrolling content: Liquid Glass on
    /// iOS 26, a material capsule before that.
    @ViewBuilder func floatingAction(prominent: Bool, tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).tint(tint).controlSize(.large)
            } else {
                self.buttonStyle(.glass).tint(tint).controlSize(.large)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(tint).controlSize(.large)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(.capsule).tint(tint).controlSize(.large)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
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

/// This app's own icon. AppIconDisplay is Icon Composer's 512 px export, mask
/// included (written by generate_icon.py): the compiled app icon only hands
/// out its 120 px fallback, which blurs at this size on a 3x screen. The
/// bundle's own icon, then an SF Symbol, are stand-ins if the asset is missing.
struct AppIconImage: View {
    var size: CGFloat = 112

    private static let display = UIImage(named: "AppIconDisplay")

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
        if let display = Self.display {
            Image(uiImage: display)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else if let image = Self.image {
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
