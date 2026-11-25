// SPDX-License-Identifier: GPL-3.0-or-later
//
// Words that mean the same thing across languages: «резюме» finds a file called
// "CV.pdf", «счёт» finds an "Invoice". Built-in groups plus the user's own ones
// (Настройки → Обучение поиска). Used by document, mail and photo-text search.

import Foundation

enum QuerySynonyms {
    /// Each group is one meaning; any word of it finds the others. Single words only.
    static let builtIn: [[String]] = [
        ["резюме", "cv", "resume", "résumé", "curriculum", "сиви"],
        ["договор", "контракт", "contract", "agreement", "contrato", "contrat"],
        ["счёт", "счет", "инвойс", "invoice", "bill", "factura", "facture"],
        ["квитанция", "чек", "receipt", "recibo", "reçu"],
        ["паспорт", "passport", "pasaporte", "passeport"],
        ["билет", "ticket", "billete", "billet"],
        ["бронирование", "бронь", "booking", "reservation", "reserva", "réservation"],
        ["страховка", "страхование", "полис", "insurance", "seguro", "assurance"],
        ["налог", "налоги", "tax", "taxes", "impuesto", "impôt"],
        ["зарплата", "salary", "payslip", "nómina", "salaire"],
        ["аренда", "rent", "lease", "rental", "alquiler", "loyer"],
        ["диплом", "diploma", "degree", "título"],
        ["сертификат", "certificate", "certificado", "certificat"],
        ["справка", "certificate", "statement"],
        ["выписка", "statement", "extracto", "relevé"],
        ["виза", "visa"],
        ["отель", "гостиница", "hotel", "hôtel"],
        ["рейс", "перелёт", "перелет", "flight", "vuelo", "vol"],
        ["поезд", "train", "tren"],
        ["заказ", "order", "pedido", "commande"],
        ["доставка", "delivery", "shipping", "envío", "livraison"],
        ["врач", "доктор", "doctor", "médico", "médecin"],
        ["собеседование", "интервью", "interview", "entrevista", "entretien"],
        ["вакансия", "vacancy", "job", "position", "empleo", "offre"],
        ["рецепт", "recipe", "receta", "recette"],
        ["презентация", "presentation", "slides", "deck"],
        ["отчёт", "отчет", "report", "informe", "rapport"],
    ]

    static let userGroupsKey = "learn.synonyms"

    /// The user's own groups, saved as lines like "резюме, CV, resume".
    static var userGroups: [[String]] {
        (UserDefaults.standard.stringArray(forKey: userGroupsKey) ?? []).map(parse).filter { $0.count >= 2 }
    }

    static func parse(_ line: String) -> [String] {
        line.split(whereSeparator: { ",;=/|".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func addUserGroup(_ line: String) {
        let words = parse(line)
        guard words.count >= 2 else { return }
        var lines = UserDefaults.standard.stringArray(forKey: userGroupsKey) ?? []
        lines.append(words.joined(separator: ", "))
        UserDefaults.standard.set(lines, forKey: userGroupsKey)
    }

    /// Lowercased, "ё" folded, letters and digits only.
    static func normalize(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е").filter { $0.isLetter || $0.isNumber }
    }

    /// Russian case endings and English plurals off, so «резюме», «договора» and
    /// "contracts" compare with the group's base words.
    static func key(_ word: String) -> String {
        let w = normalize(word)
        if w.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) { return PlaceIndex.stem(w) }
        if w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
    }

    /// Other words for the same thing (the word itself not included), user groups first.
    static func alternatives(for word: String) -> [String] {
        let k = key(word)
        guard !k.isEmpty else { return [] }
        var seen: Set<String> = [normalize(word)]
        var out: [String] = []
        for group in userGroups + builtIn where group.contains(where: { key($0) == k }) {
            for member in group {
                // Multi-word user entries go in as their words.
                for part in member.split(separator: " ").map(String.init) where seen.insert(normalize(part)).inserted {
                    out.append(part.lowercased())
                }
            }
        }
        return out
    }

    /// Each query word with its alternatives: [[word, alt1, alt2], ...].
    static func groups(for words: [String]) -> [[String]] {
        words.map { [$0] + alternatives(for: $0) }
    }

    /// Text for a meaning model: the query plus the other words for its terms, so a
    /// one-word query like «резюме» also lands near English "CV" documents.
    static func expandedText(_ text: String) -> String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard words.count <= 3 else { return text }
        let extra = words.flatMap { alternatives(for: $0).prefix(3) }
        return extra.isEmpty ? text : text + " (" + extra.joined(separator: ", ") + ")"
    }
}
