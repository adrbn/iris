import SwiftUI

/// What each control of the glasses does with Iris. Shown in Outils and as the last onboarding page.
struct GlassesGuide: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                Text("Guide des lunettes").font(.largeTitle.bold()).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader).padding(.top, 8)
                GlassesGuideList()
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
    }
}

struct GlassesGuideList: View {
    static let items: [(icon: String, title: String, detail: String)] = [
        ("mic.fill", "Bouton IA, branche gauche",
         "Appuie, attends le bip, pose ta question. Iris répond à voix haute, puis t'écoute encore 6 s pour que tu puisses lui répondre."),
        ("iphone", "Gros bouton orange de l'accueil",
         "Même chose avec le micro de l'iPhone. Touche-le à nouveau pour couper avant la fin."),
        ("eye", "« Qu'est-ce que je regarde ? »",
         "Quand ta question parle de ce que tu vois, Iris prend une photo toute seule. Sinon, rien ne part."),
        ("safari", "Dis « guide »",
         "Photo + ta position + Wikipédia : Iris te raconte le lieu où tu es."),
        ("hand.tap", "Tap, double tap, glissés",
         "Chaque geste sur la branche peut lancer une action : Réglages → Gestes."),
        ("camera", "Photos et vidéos des lunettes",
         "Elles restent dans les lunettes. Onglet Médias → flèche : Iris les rapatrie par le Wi-Fi des lunettes."),
        ("bolt.fill", "Recharge",
         "Lunettes branchées et Iris ouverte récemment : la Dynamic Island affiche leur charge."),
        ("exclamationmark.triangle", "Une seule appli à la fois",
         "Les lunettes ne parlent qu'à une appli. Ferme Genimiro (balaye-la vers le haut) avant d'utiliser Iris."),
    ]

    var body: some View {
        Card {
            ForEach(Array(Self.items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.icon).font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(Theme.glyphBox, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.callout.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text(item.detail).font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    if i < Self.items.count - 1 { Theme.separator.frame(height: 1).padding(.leading, 64) }
                }
            }
        }
    }
}
