import SwiftUI

/// Three tabs. The native iOS 26 TabView draws the Liquid Glass bar and shrinks it while scrolling down.
struct HomeView: View {
    @StateObject private var session = Session()
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        TabView {
            Tab("Accueil", systemImage: "eyeglasses") {
                NavigationStack { HomeScreen(session: session, glasses: session.glasses) }
            }
            Tab("Médias", systemImage: "photo.on.rectangle") {
                NavigationStack { MediaScreen(glasses: session.glasses, media: session.media) }
            }
            Tab("Réglages", systemImage: "gearshape") {
                SettingsSheet(session: session)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Theme.accent)
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            Onboarding(session: session, glasses: session.glasses) { onboarded = true }
        }
    }
}

/// Observes Session, Glasses and Media directly: a nested ObservableObject change would never
/// refresh a view that only observes Session.
struct HomeScreen: View {
    @ObservedObject var session: Session
    @ObservedObject var glasses: Glasses
    @State private var eventAt = Date()
    @State private var viewport: CGFloat = 0

    private var mood: GlassesMood {
        switch glasses.state {
        case .off: .off
        case .searching, .connecting: .connecting
        case .ready: glasses.recordingSince != nil ? .video : glasses.listening ? .listening : .ready
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gap) {
                // The first screen fills the viewport, blocks spread out, so Outils starts below the fold.
                VStack(spacing: 0) {
                StatusCard(name: glasses.name, mood: mood, battery: glasses.battery, charging: glasses.charging,
                           worn: glasses.worn, hotspot: glasses.hotspot, event: event)
                    .edEnter()
                Spacer(minLength: Theme.gap)
                PrimaryAskButton(listening: glasses.listening || session.phoneListening) {
                    glasses.listening ? glasses.stopListening() : session.askByPhone()
                }
                .edEnter()
                Spacer(minLength: Theme.gap)
                HStack(spacing: Theme.gap) {
                    ActionTile(title: "Photo", subtitle: session.busy ? "Analyse…" : "", icon: "camera") { glasses.takeAIPhoto() }
                    ActionTile(title: "Guide", subtitle: "Qu'est-ce que je regarde ?", icon: "safari") { session.tour() }
                }
                .disabled(!mood.usable)
                .edEnter()
                Spacer(minLength: Theme.gap)
                secondaryActions.edEnter()
                Spacer(minLength: Theme.gap)
                TranscriptLine(text: transcript).edEnter()
                }
                .frame(minHeight: max(0, viewport - 8 - Theme.gap), alignment: .top)

                links.edEnter()
                history
            }
            .padding(.horizontal, Theme.margin)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: glasses.lastEvent) { eventAt = Date() }
    }

    private var secondaryActions: some View {
        HStack(alignment: .top) {
            RoundActionButton(icon: glasses.recordingSince == nil ? "video" : "stop.fill",
                              tint: glasses.recordingSince == nil ? Theme.ink : .red,
                              accessibility: glasses.recordingSince == nil ? "Vidéo" : "Arrêter la vidéo",
                              action: glasses.toggleVideo) {
                if let since = glasses.recordingSince {
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        let s = max(0, Int(ctx.date.timeIntervalSince(since)))
                        Text(String(format: "Arrêter · %02d:%02d", s / 60, s % 60)).monospacedDigit()
                    }
                } else {
                    Text("Vidéo")
                }
            }
            .disabled(!mood.usable)
            RoundActionButton(icon: "shazam.logo", accessibility: "Quelle musique ?", action: session.shazam) {
                Text("Quelle musique ?")
            }
            NavigationLink { LiveView(glasses: glasses, server: session.liveServer) } label: {
                VStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.title3).foregroundStyle(Theme.ink)
                        .frame(width: 56, height: 56).background(Theme.surface2, in: Circle())
                    Text("En direct").font(.caption).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(Pressable())
            .accessibilityLabel("Aperçu en direct")
        }
        .padding(.vertical, 4)
    }

    /// Live words while listening, then any notice; when the glasses are away, why.
    private var transcript: String {
        if !session.hearing.isEmpty, glasses.listening || session.phoneListening { return session.hearing }
        if !session.notice.isEmpty { return session.notice }
        if !mood.usable { return "Lunettes : \(glasses.state.rawValue.lowercased())" }
        return session.hearing
    }

    private var event: String {
        guard !glasses.lastEvent.isEmpty else { return "" }
        let minutes = Int(Date().timeIntervalSince(eventAt) / 60)
        return glasses.lastEvent + " · " + (minutes < 1 ? "à l'instant" : "\(minutes) min")
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
        SectionHeader("Outils")
        Card {
            LinkRow(title: "Traducteur de conversation") { TranslatorView() }
            LinkRow(title: "Interprétation simultanée") { InterpreterView() }
            LinkRow(title: "Traduction de photos") { PhotoTranslateView(session: session, glasses: glasses) }
            LinkRow(title: "Notes vocales") { VoiceNotesView(notes: session.notes) }
            LinkRow(title: "Journal du soir") { JournalView(journal: session.journal, write: session.writeJournal) }
            LinkRow(title: "Mémoire photo") { MemoryView(memory: session.memory) }
            LinkRow(title: "Réglages des lunettes") { GlassesSettings(glasses: glasses) }
            LinkRow(title: "Guide des lunettes") { GlassesGuide() }
            Button { UserDefaults.standard.set(false, forKey: "onboarded") } label: {
                HStack {
                    Text("Revoir la présentation").font(.body).foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "arrow.counterclockwise").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 18).padding(.vertical, 15).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) { Theme.separator.frame(height: 1).padding(.leading, 18) }
            LinkRow(title: "Journal technique", last: true) { LogView() }
        }
        }
    }

    @ViewBuilder private var history: some View {
        if !session.shots.isEmpty {
            SectionHeader(title: "Historique") { Meta("Aujourd'hui") }
            ForEach(session.shots) { shot in
                NavigationLink { ShotDetail(shot: shot) } label: {
                    HistoryRow(image: shot.image, date: shot.date,
                               question: shot.title.isEmpty ? (shot.question.isEmpty ? "Photo" : shot.question) : shot.title,
                               answer: shot.answer) { session.analyze(shot.id) }
                }
                .buttonStyle(.plain)
                .edEnter()
            }
        }
    }
}

/// Onglet Médias : ce que les lunettes ont filmé ou photographié, rapatrié par Wi-Fi.
/// « Sélectionner » coche plusieurs vignettes pour les supprimer ou partager d'un coup.
struct MediaScreen: View {
    @ObservedObject var glasses: Glasses
    @ObservedObject var media: Media
    @State private var selecting = false
    @State private var selected: Set<URL> = []
    @State private var confirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                header
                if media.busy || !media.status.isEmpty { TransferCard(media: media) }
                if media.files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(Theme.muted)
                        Text("Aucun média").font(.headline).foregroundStyle(Theme.ink)
                        Text("Les photos et vidéos des lunettes arrivent ici. Touche la flèche pour les récupérer.")
                            .font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 48).padding(.horizontal, 24)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(media.files, id: \.self) { url in cell(url).edEnter() }
                    }
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.top, 8)
            .padding(.bottom, selecting ? 96 : 24)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
        .confirmationDialog("Supprimer \(selected.count) élément(s) de l'iPhone ?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { media.delete(selected); selected = []; selecting = false }
        }
        .onChange(of: media.files) { selected.formIntersection(media.files) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Médias").font(.largeTitle.bold()).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            Text("\(media.files.count)").font(Theme.mono(.footnote)).foregroundStyle(Theme.muted)
            Spacer()
            if !media.files.isEmpty {
                Button(selecting ? "OK" : "Sélectionner") { selecting.toggle(); selected = [] }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14).frame(height: 44).background(Theme.surface2, in: Capsule())
            }
            if !selecting {
                Button(action: media.fetch) {
                    Group {
                        if media.busy { ProgressView() } else { Image(systemName: "arrow.down") }
                    }
                    .font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44).background(Theme.surface2, in: Circle())
                }
                .disabled(media.busy || glasses.state != .ready)
                .accessibilityLabel(media.busy ? "Transfert en cours" : "Télécharger depuis les lunettes")
            }
        }
    }

    @ViewBuilder private func cell(_ url: URL) -> some View {
        let thumb = Thumbnail(url: url).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        if selecting {
            let on = selected.contains(url)
            Button { if on { selected.remove(url) } else { selected.insert(url) } } label: {
                thumb
                    .opacity(on ? 0.6 : 1)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(on ? Theme.accent : .white)
                            .background(on ? Circle().fill(.white) : nil)
                            .shadow(radius: 2).padding(6)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
        } else {
            NavigationLink { MediaDetail(url: url, media: media) } label: { thumb }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: Theme.gap) {
            Button(selected.count == media.files.count ? "Aucun" : "Tout") {
                selected = selected.count == media.files.count ? [] : Set(media.files)
            }
            .foregroundStyle(Theme.ink)
            Spacer()
            Text(selected.isEmpty ? "Touche les vignettes" : "\(selected.count) sélectionné(s)")
                .font(.footnote).foregroundStyle(Theme.muted)
            Spacer()
            ShareLink(items: Array(selected)) { Image(systemName: "square.and.arrow.up") }
                .disabled(selected.isEmpty)
            Button(role: .destructive) { confirm = true } label: { Image(systemName: "trash") }
                .disabled(selected.isEmpty)
        }
        .font(.body.weight(.semibold))
        .tint(Theme.accent)
        .padding(.horizontal, 20).frame(height: 56)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, Theme.margin).padding(.bottom, 8)
    }
}

/// While transferring: what step, which file, a real progress bar (bytes), overall count.
private struct TransferCard: View {
    @ObservedObject var media: Media

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: media.busy ? "wifi" : "checkmark")
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: media.busy && media.transfer == nil)
                Text(media.status).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer()
                if let t = media.transfer {
                    Text("\(t.index) sur \(t.count)").font(Theme.mono(.footnote)).foregroundStyle(Theme.muted)
                }
            }
            if let t = media.transfer {
                ProgressView(value: overall(t)).tint(Theme.accent)
                HStack {
                    Text(t.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(bytes(t)).monospacedDigit()
                }
                .font(.footnote).foregroundStyle(Theme.muted)
            } else if media.busy {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.default, value: media.transfer)
    }

    /// Done files plus the current one's fraction.
    private func overall(_ t: Media.Transfer) -> Double {
        let part = t.total > 0 ? Double(t.received) / Double(t.total) : 0
        return (Double(t.index - 1) + part) / Double(max(t.count, 1))
    }

    private func bytes(_ t: Media.Transfer) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return t.total > 0 ? "\(f.string(fromByteCount: t.received)) / \(f.string(fromByteCount: t.total))" : f.string(fromByteCount: t.received)
    }
}

/// La photo en grand, avec sa question et la réponse.
struct ShotDetail: View {
    let shot: Shot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let image = shot.image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                if !shot.question.isEmpty { Text(shot.question).font(.headline).foregroundStyle(Theme.ink) }
                Text(shot.answer).foregroundStyle(Theme.muted).textSelection(.enabled)
            }
            .padding(Theme.margin)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(Text(shot.date, format: .dateTime.hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
    }
}
