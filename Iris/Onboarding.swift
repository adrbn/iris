import AVFoundation
import Speech
import SwiftUI

/// First launch: what Iris is, the glasses connection (live), permissions explained before iOS asks,
/// which brain answers, then the controls. Shown once (`onboarded`), replayable from Outils.
/// Design: Claude Design « Iris Onboarding » (five pages, hand-drawn dots, Liquid Glass bottom bar).
struct Onboarding: View {
    @ObservedObject var session: Session
    @ObservedObject var glasses: Glasses
    let done: () -> Void
    @State private var page = 0
    @State private var micOK = AVAudioApplication.shared.recordPermission == .granted
    @State private var speechOK = SFSpeechRecognizer.authorizationStatus() == .authorized
    @State private var tick = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let last = 4
    private var connected: Bool { glasses.state == .ready }
    private static let examples: [(question: String, photo: Bool)] = [
        ("Quelle heure est-il à Tokyo ?", false),
        ("C'est quoi ce bâtiment ?", true),
        ("Rappelle-moi d'acheter du pain", false),
    ]

    var body: some View {
        TabView(selection: $page) {
            welcome.tag(0)
            connect.tag(1)
            permissions.tag(2)
            brain.tag(3)
            commands.tag(4)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .background(Theme.background.ignoresSafeArea())
        .interactiveDismissDisabled()
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.8))
                withAnimation(.easeInOut(duration: 0.4)) { tick = (tick + 1) % Self.examples.count }
            }
        }
    }

    // MARK: bottom bar

    private var bottomBar: some View {
        VStack(spacing: 18) {
            HStack(spacing: 7) {
                ForEach(0...last, id: \.self) { i in
                    Capsule().fill(Theme.ink)
                        .frame(width: i == page ? 20 : 7, height: 7)
                        .opacity(i == page ? 1 : 0.22)
                        .contentShape(Rectangle().inset(by: -6))
                        .onTapGesture { withAnimation(.spring(duration: 0.35)) { page = i } }
                }
            }
            .animation(.spring(duration: 0.35), value: page)
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) sur \(last + 1)")

            Button {
                if page < last { withAnimation { page += 1 } } else { done() }
            } label: {
                Text(page < last ? "Continuer" : "C'est parti")
                    .font(.headline).foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Theme.accent, in: Capsule())
                    .contentTransition(.opacity)
            }
            .buttonStyle(Pressable())
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .padding(.horizontal, 8)
    }

    // MARK: P1 welcome

    private var welcome: some View {
        let example = Self.examples[tick]
        return VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                Spacer(minLength: 0)
                GlassesModelView(mood: .ready).frame(height: 250)
                VStack(spacing: 7) {
                    Text("« \(example.question) »").font(.system(size: 16)).foregroundStyle(Theme.ink)
                    Label(example.photo ? "Photo" : "Sans photo", systemImage: example.photo ? "camera" : "eye.slash")
                        .font(.system(size: 12, weight: .semibold)).tracking(0.7).textCase(.uppercase)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(example.photo ? Theme.accent : Theme.muted, example.photo ? Theme.ink : Theme.muted)
                }
                .contentTransition(.opacity)
                .frame(minHeight: 52)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            Text("Iris").font(.system(size: 44, weight: .bold)).tracking(-0.9).foregroundStyle(Theme.ink)
            Text("Pose une question à tes lunettes, elles te répondent à l'oreille.")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink).padding(.top, 12)
            Text("Elles regardent seulement quand ta question en a besoin.")
                .font(.system(size: 17)).foregroundStyle(Theme.muted).padding(.top, 8)
        }
        .padding(.horizontal, 20).padding(.bottom, 22)
    }

    // MARK: P2 connect

    private var connect: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("Tes lunettes").padding(.bottom, 8)
            stateCard
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Allume les lunettes", "Rien à appairer dans les Réglages de l'iPhone.")
                step(2, "Ferme Genimiro", "Balaye-la vers le haut : une seule appli à la fois.")
                step(3, "Autorise le Bluetooth", "iOS te le demande une fois.")
            }
            .padding(20)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .opacity(connected ? 0.45 : 1)
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
        .animation(.spring(duration: 0.5), value: connected)
        .sensoryFeedback(.success, trigger: connected) { _, now in now }
    }

    @ViewBuilder private var stateCard: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(spacing: 20) {
            if connected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 76)).foregroundStyle(Theme.accent)
                    .transition(.scale.combined(with: .opacity))
                Text("\(Text(glasses.name).font(.system(size: 20, weight: .medium, design: .monospaced))) connectées")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(scheme == .light ? .white : Theme.ink)
            } else {
                PulsingGlyph(animate: !reduceMotion)
                HStack(spacing: 10) {
                    ProgressView()
                    Text(glasses.state == .searching ? "Recherche…" : glasses.state.rawValue)
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                if !reduceMotion { IndeterminateBar().frame(width: 140, height: 3) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 200)
        .background(connected && scheme == .light ? Theme.ink : Theme.surface, in: shape)
        .overlay { if connected && scheme == .dark { shape.strokeBorder(Theme.accent, lineWidth: 1.5) } }
        .accessibilityElement(children: .combine)
    }

    // MARK: P3 permissions

    private var permissions: some View {
        centered(symbol: "checkmark.shield", title: "Ce qu'Iris utilise") {
            VStack(spacing: 10) {
                permission("mic.fill", "Micro", "Pour t'écouter et traduire.", micOK) {
                    micOK = await AVAudioApplication.requestRecordPermission()
                }
                permission("waveform", "Reconnaissance vocale", "Ta voix en texte, sur l'iPhone si possible.", speechOK) {
                    speechOK = await withCheckedContinuation { c in
                        SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
                    }
                }
            }
            note("Tes photos et questions ne partent que vers l'IA que tu choisis. La position n'est demandée qu'au premier « guide ».")
                .padding(.top, 16)
        }
    }

    // MARK: P4 brain

    private var brain: some View {
        centered(symbol: "sparkles", title: "Qui répond ?") {
            HStack(spacing: 10) {
                BrainCard(symbol: "apple.logo", title: "IA d'Apple", detail: "Sur l'iPhone, gratuite, sans clé.",
                          selected: session.appleBrain) { session.appleBrain = true }
                BrainCard(symbol: "cloud", title: "Fournisseur",
                          detail: "Gemini, OpenAI… avec ta clé. Apple prend le relais s'il ne répond pas.",
                          selected: !session.appleBrain) { session.appleBrain = false }
            }
            .animation(.spring(duration: 0.35), value: session.appleBrain)
            .sensoryFeedback(.selection, trigger: session.appleBrain)
            note("L'IA d'Apple voit mal les images avant iOS 27. Une clé Gemini gratuite fait mieux : colle-la dans Réglages → Fournisseur IA.")
                .padding(.top, 16)
            if let url = URL(string: "https://aistudio.google.com/apikey") {
                Link("Obtenir une clé Gemini", destination: url)
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.accent).padding(.top, 10)
            }
        }
    }

    // MARK: P5 commands

    private static let ask: [(String, String, String)] = [
        ("eyeglasses", "Bouton IA, branche gauche", "Appuie, attends le bip, parle. Iris répond puis t'écoute encore 6 s."),
        ("mic", "Gros bouton orange de l'accueil", "Pareil, avec le micro de l'iPhone."),
        ("eye", "« Qu'est-ce que je regarde ? »", "La photo ne part que si ta question parle de ce que tu vois."),
        ("safari", "Dis « guide »", "Photo, position et Wikipédia : Iris raconte le lieu."),
    ]
    private static let more: [(String, String, String)] = [
        ("hand.tap", "Tap, double tap, glissés", "Une action par geste, dans Réglages → Gestes."),
        ("camera", "Photos et vidéos des lunettes", "À rapatrier dans Médias, par le Wi-Fi des lunettes."),
        ("bolt.fill", "Recharge", "La charge des lunettes s'affiche dans la Dynamic Island."),
    ]

    private var commands: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title("Les commandes").padding(.bottom, 18)
                group("Poser une question", Self.ask)
                group("Et aussi", Self.more).padding(.top, 22)
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func group(_ header: String, _ rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(header).font(.system(size: 13, weight: .semibold)).tracking(0.5).textCase(.uppercase)
                .foregroundStyle(Theme.muted).padding(.horizontal, 6).padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: row.0).font(.system(size: 19, weight: .medium)).foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                            .background(Theme.glyphBox, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.1).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text(row.2).font(.system(size: 15)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 14)
                    .overlay(alignment: .top) { if i > 0 { Theme.separator.frame(height: 1) } }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 2)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    // MARK: pieces

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.ink)
            .padding(.top, 24).accessibilityAddTraits(.isHeader)
    }

    /// Big symbol + title + content, vertically centred (pages 3 and 4).
    private func centered<C: View>(symbol: String, title text: String, @ViewBuilder content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol).font(.system(size: 52, weight: .medium)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(text).font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.ink)
                    .padding(.top, 14).padding(.bottom, 18).accessibilityAddTraits(.isHeader)
                content()
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerRelativeFrame(.vertical, alignment: .center) { h, _ in h }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.subheadline.weight(.bold)).foregroundStyle(Theme.onAccent)
                .frame(width: 28, height: 28).background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(.system(size: 15)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
    }

    private func permission(_ icon: String, _ title: String, _ detail: String, _ granted: Bool,
                            ask: @escaping () async -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.accent)
                .frame(width: 52, height: 52)
                .background(Theme.glyphBox, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(.system(size: 15)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: granted)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Autorisé")
            } else {
                Button("Autoriser") { Task { await ask() } }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 16).frame(height: 40).background(Theme.accent, in: Capsule())
                    .buttonStyle(Pressable())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.spring(duration: 0.4), value: granted)
    }
}

/// 200 pt selectable card: filled with ink in light mode, outlined in orange in dark mode.
private struct BrainCard: View {
    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var filled: Bool { selected && scheme == .light }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: symbol).font(.system(size: 28, weight: .regular))
                        .foregroundStyle(filled ? Theme.accent : Theme.ink)
                    Spacer()
                    ZStack {
                        Circle().strokeBorder(Theme.outline, lineWidth: 1.5).opacity(selected ? 0 : 1)
                        Circle().fill(Theme.accent).opacity(selected ? 1 : 0)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.onAccent).opacity(selected ? 1 : 0)
                    }
                    .frame(width: 26, height: 26)
                }
                Spacer(minLength: 8)
                Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(filled ? .white : Theme.ink)
                Text(detail).font(.system(size: 14)).foregroundStyle(filled ? Color(hex: 0xA8A8A8) : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 200, alignment: .leading)
            .background(filled ? Theme.ink : Theme.surface, in: shape)
            .overlay { shape.strokeBorder(Theme.accent, lineWidth: 1.5).opacity(selected && scheme == .dark ? 1 : 0) }
        }
        .buttonStyle(Pressable())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Glasses glyph in a dark disc with three orange rings pinging outward (searching state).
private struct PulsingGlyph: View {
    let animate: Bool

    var body: some View {
        TimelineView(.animation(paused: !animate)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle().strokeBorder(Theme.accent, lineWidth: 1.5)
                        .scaleEffect(0.58 + 0.42 * phase)
                        .opacity(animate ? 0.7 * (1 - phase) : 0)
                }
                Image(systemName: "eyeglasses").font(.system(size: 34, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: 76, height: 76)
                    .background(Color(hex: 0x0A0A0A), in: Circle())
            }
            .frame(width: 132, height: 132)
        }
        .accessibilityHidden(true)
    }
}

/// 3 pt indeterminate progress bar: a short orange segment sliding along a track.
private struct IndeterminateBar: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            GeometryReader { geo in
                Capsule().fill(Theme.track)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent).frame(width: geo.size.width * 0.35)
                            .offset(x: geo.size.width * (1.35 * phase - 0.35))
                    }
                    .clipShape(Capsule())
            }
        }
        .accessibilityHidden(true)
    }
}
