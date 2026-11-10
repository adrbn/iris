import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var session: Session
    @AppStorage("sendImage") private var sendImage = "auto"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    Text("Réglages").font(.largeTitle.bold()).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                        .padding(.top, 8)

                    label("Cerveau")
                    HStack(spacing: Theme.gap) {
                        BrainChoiceCard(title: "IA d'Apple", detail: "Sur l'iPhone · privée · gratuite",
                                        selected: session.appleBrain) { session.appleBrain = true }
                        BrainChoiceCard(title: "Fournisseur", detail: "Compatible OpenAI · ta clé",
                                        selected: !session.appleBrain) { session.appleBrain = false }
                    }
                    note(session.appleBrain
                         ? "C'est l'IA d'Apple qui répond, rien ne sort du téléphone. \(Brain.appleStatus)"
                         : "C'est le fournisseur ci-dessous qui répond (Gemini, OpenRouter, Groq…), avec ta clé. Choisis un modèle qui « voit les images » pour l'analyse des photos.")

                    label("Fournisseur IA")
                    ProviderCard(baseURL: $session.baseURL, model: $session.model)
                    note("Chaque fournisseur garde sa clé et son modèle.")

                    label("Consigne")
                    TextEditor(text: $session.prompt)
                        .scrollContentBackground(.hidden).foregroundStyle(Theme.ink)
                        .frame(minHeight: 120).padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    label("Gestes")
                    Card {
                        ForEach(Array(GestureAction.gestures.enumerated()), id: \.element.0) { i, gesture in
                            GestureRow(key: gesture.0, label: gesture.1, last: i == GestureAction.gestures.count - 1)
                        }
                    }
                    note("« Rien » laisse le firmware faire son action d'origine. Tous les gestes n'arrivent pas forcément au téléphone : l'accueil affiche le dernier reçu. Télécommande Mac : \(session.macRemote)")

                    label("Lecture")
                    Card {
                        toggle("Analyser chaque photo", $session.autoAnalyze)
                        toggle("Lire la réponse à voix haute", $session.speak)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Photo avec une question vocale").foregroundStyle(Theme.ink)
                            Picker("Photo avec une question vocale", selection: $sendImage) {
                                Text("Auto").tag("auto"); Text("Toujours").tag("always"); Text("Jamais").tag("never")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
                    }
                    note("Auto : la photo part seulement si ta question parle de ce que tu vois. Le bouton Photo et le guide envoient toujours l'image.")
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Theme.accent)
    }

    private func label(_ text: String) -> some View { Meta(text).padding(.top, 14).padding(.leading, 4) }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Theme.muted).padding(.horizontal, 4)
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(title, isOn: value).foregroundStyle(Theme.ink).tint(Theme.accent)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Theme.separator.frame(height: 1).padding(.leading, 18) }
    }
}

struct BrainChoiceCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var filled: Bool { selected && scheme == .light }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Spacer()
                    Image(systemName: "checkmark").opacity(selected ? 1 : 0)
                        .font(.caption.weight(.bold)).foregroundStyle(Theme.onAccent)
                        .frame(width: 22, height: 22)
                        .background(selected ? Theme.accent : Theme.track, in: Circle())
                }
                Spacer(minLength: 6)
                Text(title).font(.headline).foregroundStyle(filled ? .white : Theme.ink)
                Text(detail).font(.caption).foregroundStyle(filled ? .white.opacity(0.7) : Theme.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .background(filled ? Theme.ink : Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                if selected && scheme == .dark {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(Pressable())
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct GestureRow: View {
    let label: String
    let glyph: String
    let last: Bool
    @AppStorage private var action: String

    init(key: String, label: String, last: Bool) {
        self.label = label
        self.last = last
        glyph = ["tap": "×1", "double": "×2", "triple": "×3", "front": "→", "back": "←", "nod": "↕", "shake": "↔"][key] ?? "·"
        _action = AppStorage(wrappedValue: GestureAction.none.rawValue, "gesture.\(key)")
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(glyph).font(Theme.mono(.callout, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.glyphBox, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            Text(label).foregroundStyle(Theme.ink)
            Spacer()
            Menu {
                Picker(label, selection: $action) {
                    ForEach(GestureAction.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text((GestureAction(rawValue: action) ?? .none).label).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.subheadline).foregroundStyle(Theme.muted)
            }
            .accessibilityLabel("\(label) : \((GestureAction(rawValue: action) ?? .none).label)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { if !last { Theme.separator.frame(height: 1).padding(.leading, 62) } }
    }
}
