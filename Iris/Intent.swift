import Foundation
import FoundationModels

/// Does a spoken question need the glasses photo? "Qu'est-ce que je regarde ?" yes,
/// "Quelle heure est-il à Tokyo ?" no. Asked to Apple's on-device model (free, ~0.5 s, nothing leaves
/// the phone), so indirect phrasings work too; the keyword list is only the fallback when that model
/// isn't available.
enum Intent {
    static func decide(_ question: String) async -> Bool {
        // No visual word at all → no photo. Apple's model alone said yes to "tu m'entends ?" and to a
        // pasta recipe (08/11): it only gets to confirm questions the keywords already flag.
        guard needsImage(question) else {
            Log.line("intent: aucun mot visuel → photo non")
            return false
        }
        if SystemLanguageModel.default.availability == .available {
            do {
                let session = LanguageModelSession(instructions: """
                    Tu décides si une question posée à des lunettes à caméra a besoin de la photo de ce que la personne regarde. \
                    Oui si elle parle de quelque chose de visible autour d'elle (objet, lieu, texte, personne, « ça », « ici », couleur, lecture, traduction d'un panneau). \
                    Non si on peut y répondre sans voir (culture générale, heure, calcul, conseil, conversation).
                    """)
                let yes = try await session.respond(to: "Question : « \(question) »", generating: Bool.self).content
                Log.line("intent: modèle Apple → photo \(yes ? "oui" : "non")")
                return yes
            } catch {
                Log.line("intent: modèle Apple en échec (\(error.localizedDescription)), mots-clés")
            }
        }
        let yes = needsImage(question)
        Log.line("intent: mots-clés → photo \(yes ? "oui" : "non")")
        return yes
    }

    static let visual = ["vois", "voit", "regarde", "c'est quoi", "qu'est-ce que c'est", "qu’est-ce que c’est", "ça", "ceci", "cela",
                         "lis", "lire", "écrit", "traduis", "traduire", "devant", "ici", "photo", "image", "couleur", "combien",
                         "cette", "ce truc", "décris", "montre", "panneau", "étiquette", "menu", "prix", "marque", "modèle", "plante",
                         "animal", "chien", "chat", "qui est", "c'est qui", "quel est ce", "quelle est cette", "où suis", "identifie"]

    static func needsImage(_ question: String) -> Bool {
        let q = " " + question.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        let words = q.components(separatedBy: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "'"))).filter { !$0.isEmpty }
        return visual.contains { key in key.contains(" ") || key.contains("'") ? q.contains(key) : words.contains(key) }
    }
}
