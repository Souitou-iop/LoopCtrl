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

/// Groups floating glass buttons so that, on iOS 26, their shapes blend and
/// morph into each other as buttons appear, disappear or resize. Before
/// iOS 26 it is a plain container.
struct FloatingGlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
    }
}

/// A compact capsule button floating over content. On iOS 26 it is Liquid
/// Glass drawn with `glassEffect` itself (not a glass button style), so it can
/// carry a `glassEffectID`: inside a `FloatingGlassGroup`, a button that
/// appears or goes away melts into its neighbour instead of popping, and a
/// change of width or tint animates on the glass. Ordinary transitions can't
/// do that — glass is rendered apart from the view's opacity and scale, so it
/// would sit unchanged through the animation and vanish on the last frame.
/// Before iOS 26 it is a material/bordered capsule with a scale-and-fade.
struct FloatingCapsuleButton<Label: View>: View {
    let prominent: Bool
    let tint: Color
    let glassID: String
    let namespace: Namespace.ID
    var role: ButtonRole? = nil
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: role, action: action) {
                label
                    .font(.body)
                    .foregroundStyle(prominent ? Color.white : Color.primary)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 50)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(prominent ? .regular.tint(tint).interactive() : .regular.interactive(), in: .capsule)
            .glassEffectID(glassID, in: namespace)
            .glassEffectTransition(.matchedGeometry)
        } else {
            Button(role: role, action: action) { label }
                .floatingAction(prominent: prominent, tint: tint)
                .transition(.scale(scale: 0.5, anchor: .trailing).combined(with: .opacity))
        }
    }
}

extension View {
    /// Hide iOS 26's bottom scroll edge effect (no-op before iOS 26).
    @ViewBuilder func bottomScrollEdgeEffectHidden() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            self
        }
    }
}
