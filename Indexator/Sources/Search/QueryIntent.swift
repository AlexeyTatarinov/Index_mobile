// SPDX-License-Identifier: GPL-3.0-or-later
//
// Guesses what kind of thing a query is after, so the results put the right
// section first: "моё резюме" wants documents, "письмо от банка" wants mail,
// "попугаи в парке" wants photos.

import Foundation

struct QueryIntent: Equatable {
    var wantsDocuments = false
    var wantsMail = false

    /// Word stems (lowercased) that point to files rather than pictures.
    static let documentStems = [
        "резюме", "cv", "resume", "договор", "контракт", "contract", "счёт", "счет", "invoice",
        "документ", "файл", "pdf", "docx", "word", "excel", "таблиц", "презентац", "отчёт", "отчет",
        "справк", "заявлен", "анкет", "инструкц", "руководств", "квитанц", "выписк", "налог",
        "декларац", "акт ", "доверенност", "полис", "страховк", "диплом", "сертификат", "приказ",
        "протокол", "смет", "бланк", "статья", "книг", "конспект", "лекци", "курсов", "реферат",
        "заметк", "report", "document", "file", "agreement", "manual", "receipt",
    ]

    /// Word stems that point to email.
    static let mailStems = [
        "письм", "почт", "email", "e-mail", "mail", "gmail", "рассылк", "переписк", "ответ от", "от банка",
        "уведомлени", "подтверждени", "бронировани", "booking", "билет", "заказ",
    ]

    static func detect(_ query: String) -> QueryIntent {
        let text = " " + query.lowercased() + " "
        var intent = QueryIntent()
        intent.wantsDocuments = documentStems.contains { text.contains($0) }
        intent.wantsMail = mailStems.contains { text.contains($0) }
        return intent
    }
}
