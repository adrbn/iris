import SwiftUI

/// What the status card, the 3D LED and the buttons show. Derived from Glasses in HomeView, plain
/// values here so every state can be previewed without Bluetooth.
enum GlassesMood {
    case ready, connecting, listening, video, off

    var label: String {
        switch self {
        case .ready: "Prêt"
        case .connecting: "Connexion…"
        case .listening: "À l'écoute"
        case .video: "Vidéo"
        case .off: "Déconnectées"
        }
    }

    var usable: Bool { self != .connecting && self != .off }
}

struct StatusCard: View {
    let name: String
    let mood: GlassesMood
    let battery: Int?
    let charging: Bool
    let worn: Bool?
    /// « Double tap · 2 min », already formatted.
    let event: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Meta(name.isEmpty ? "Lunettes" : name)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(mood == .off ? Theme.muted : Theme.accent).frame(width: 7, height: 7)
                    Text(mood.label).font(.footnote.weight(.medium)).foregroundStyle(Theme.ink)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.chip, in: Capsule())
            }
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(battery.map(String.init) ?? "—")
                        .font(.system(size: 76, weight: .medium, design: .monospaced)).tracking(-4)
                        .foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                    Text("%").font(.system(size: 24, design: .monospaced)).foregroundStyle(Theme.muted)
                    if charging { Image(systemName: "bolt.fill").foregroundStyle(Theme.accent).accessibilityLabel("En charge") }
                }
                Spacer(minLength: 0)
                GlassesModelView(mood: mood).frame(width: 128, height: 72)
            }
            HStack(spacing: 6) {
                if let worn { Text(worn ? "Portées" : "Posées").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink) }
                if !event.isEmpty { Text(event).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            GeometryReader { geo in
                Capsule().fill(Theme.track)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.batteryFill).frame(width: geo.size.width * CGFloat(battery ?? 0) / 100)
                    }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct PrimaryAskButton: View {
    let listening: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: listening ? "waveform" : "mic.fill")
                        .font(.title3).foregroundStyle(Theme.accent)
                        .frame(width: 50, height: 50).background(Theme.ink, in: Circle())
                        .symbolEffect(.variableColor.iterative, isActive: listening)
                    Spacer()
                    Text("OU TAP SUR LA BRANCHE").font(Theme.mono()).tracking(1.1).foregroundStyle(Theme.onAccent.opacity(0.75))
                }
                Spacer(minLength: 14)
                Text(listening ? "Terminer la question" : "Demander à Iris")
                    .font(.title.bold()).foregroundStyle(Theme.onAccent)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        .buttonStyle(Pressable())
        .accessibilityLabel(listening ? "Terminer la question" : "Demander à Iris")
        .accessibilityHint("Ou touche la branche des lunettes")
    }
}

struct ActionTile: View {
    let title: String
    var subtitle = ""
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: icon).font(.title3).foregroundStyle(Theme.ink)
                Spacer(minLength: 10)
                Text(title).font(.headline).foregroundStyle(Theme.ink)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(Theme.muted).lineLimit(2) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(Pressable())
    }
}

/// Cercle 56 pt + légende. `label` is the caption view so Vidéo can show its live timer.
struct RoundActionButton<Caption: View>: View {
    let icon: String
    var tint = Theme.ink
    let accessibility: String
    let action: () -> Void
    @ViewBuilder let caption: Caption

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
                    .frame(width: 56, height: 56).background(Theme.surface2, in: Circle())
                caption.font(.caption).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(Pressable())
        .accessibilityLabel(accessibility)
    }
}

struct TranscriptLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("›").foregroundStyle(Theme.accent).fontWeight(.bold)
            Text(text.isEmpty ? "…" : text).foregroundStyle(text.isEmpty ? Theme.muted : Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.mono(.footnote))
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
        .accessibilityLabel(text.isEmpty ? "Transcription vide" : text)
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title2.bold()).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            trailing
            Spacer()
        }
        .padding(.top, 8)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

struct HistoryRow: View {
    let image: UIImage?
    let date: Date
    let question: String
    let answer: String
    let analyze: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "waveform").font(.title3).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.chip) }
            }
            .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(date, format: .dateTime.hour().minute()).font(Theme.mono()).foregroundStyle(Theme.muted)
                Text(question).font(.callout.weight(.semibold)).foregroundStyle(Theme.ink)
                if answer.isEmpty {
                    Button(action: analyze) {
                        Text("Analyser avec l'IA").font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(scheme == .dark ? Theme.accent : .white)
                            .background(scheme == .dark ? Color.clear : Theme.ink, in: Capsule())
                            .overlay { if scheme == .dark { Capsule().strokeBorder(Theme.accent, lineWidth: 1) } }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                } else {
                    Text(answer).font(.subheadline).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// Carte blanche/sombre qui groupe des lignes (liens, réglages).
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// Ligne de lien 17 pt + chevron, séparateur dessous sauf la dernière.
struct LinkRow<Destination: View>: View {
    let title: String
    var last = false
    @ViewBuilder let destination: Destination

    var body: some View {
        NavigationLink { destination } label: {
            HStack {
                Text(title).font(.body).foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 18).padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { if !last { Theme.separator.frame(height: 1).padding(.leading, 18) } }
    }
}

struct Pressable: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// edEnter: a block fades in and rises 12 pt as it scrolls into view, and fades out as it
/// leaves. Armed after 150 ms so the first screen doesn't animate in on launch.
private struct EdEnter: ViewModifier {
    @State private var armed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scrollTransition(axis: .vertical) { [on = armed && !reduceMotion] view, phase in
                view.opacity(!on || phase.isIdentity ? 1 : 0).offset(y: !on || phase.isIdentity ? 0 : 12)
            }
            .task { try? await Task.sleep(for: .milliseconds(150)); armed = true }
    }
}

extension View {
    func edEnter() -> some View { modifier(EdEnter()) }
}
