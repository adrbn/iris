import SwiftUI

/// Photo translation: the glasses take a photo, the brain reads every visible text and gives it in
/// French (read aloud too). Full-resolution Wi-Fi photos are read on-device instead (Médias → texte).
struct PhotoTranslateView: View {
    @ObservedObject var session: Session
    @ObservedObject var glasses: Glasses

    private var results: [Shot] { session.shots.filter { $0.title == PhotoTranslate.title } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                Button { session.translatePhoto() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: session.busy ? "hourglass" : "camera.viewfinder").font(.title2.weight(.semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.busy ? "Traduction…" : "Traduire ce que je regarde").font(.headline)
                            Text("Panneau, menu, étiquette : vise et touche.").font(.footnote).opacity(0.75)
                        }
                        Spacer()
                    }
                    .foregroundStyle(Theme.onAccent)
                    .padding(18)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .buttonStyle(Pressable())
                .disabled(glasses.state != .ready || session.busy)

                Text("Tu peux aussi dire « traduis ça » avec le bouton IA. Pour un long texte, prends la photo avec le bouton des lunettes puis ouvre-la dans Médias → icône texte : elle est en pleine résolution.")
                    .font(.footnote).foregroundStyle(Theme.muted).padding(.horizontal, 4)

                ForEach(results) { shot in
                    VStack(alignment: .leading, spacing: 10) {
                        if let image = shot.image {
                            Image(uiImage: image).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        Text(shot.answer.isEmpty || shot.answer == "…" ? "Lecture…" : shot.answer)
                            .font(.body).foregroundStyle(Theme.ink).textSelection(.enabled)
                        Text(shot.date, format: .dateTime.hour().minute()).font(Theme.mono()).foregroundStyle(Theme.muted)
                    }
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Traduction de photos")
    }
}

enum PhotoTranslate {
    static let title = "Traduction"
    static let prompt = "Lis tout le texte visible sur la photo et donne-le traduit en français, dans l'ordre, sans commentaire. S'il est déjà en français, recopie-le. S'il n'y a aucun texte, dis-le en une phrase."
}
