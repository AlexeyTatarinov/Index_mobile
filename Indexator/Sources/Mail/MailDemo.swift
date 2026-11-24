// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sample emails for simulator screenshots and tests (`-mailDemo YES`). Never used otherwise.

import Foundation

enum MailDemo {
    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: 10))!
    }

    static let messages: [MailMessage] = [
        MailMessage(id: "demo1", threadId: "demo1", subject: "Ваш билет: Париж — Барселона, 14 июля",
                    sender: "Renfe-SNCF <tickets@example.com>", recipients: "me@example.com", date: day(2025, 6, 2),
                    snippet: "Электронный билет на поезд, вагон 12, место 45",
                    body: "Здравствуйте! Ваш электронный билет на поезд Париж — Барселона отправлением 14 июля в 10:07. Вагон 12, место 45. Покажите QR-код контролёру.",
                    labels: ["INBOX"], attachments: ["ticket.pdf"]),
        MailMessage(id: "demo2", threadId: "demo2", subject: "Счёт за электричество за октябрь",
                    sender: "EDF <factures@example.com>", recipients: "me@example.com", date: day(2025, 11, 5),
                    snippet: "Сумма к оплате 84,20 €, срок до 20 ноября",
                    body: "Ваш счёт за электроэнергию за октябрь готов. Сумма к оплате: 84,20 €. Оплатить до 20 ноября.",
                    labels: ["INBOX"], attachments: ["facture-octobre.pdf"]),
        MailMessage(id: "demo3", threadId: "demo3", subject: "Re: шашлыки в субботу",
                    sender: "Петя Иванов <petya@example.com>", recipients: "me@example.com", date: day(2025, 8, 21),
                    snippet: "Я возьму мангал и угли, с тебя мясо",
                    body: "Привет! Давай в субботу на озере. Я возьму мангал и угли, с тебя мясо и овощи. Начинаем в два.",
                    labels: ["INBOX"], attachments: []),
        MailMessage(id: "demo4", threadId: "demo4", subject: "Your order has shipped",
                    sender: "Shop <orders@example.com>", recipients: "me@example.com", date: day(2025, 10, 12),
                    snippet: "Wireless headphones are on their way",
                    body: "Good news! Your wireless headphones have shipped and should arrive in 3-5 business days. Tracking number 1Z999.",
                    labels: ["INBOX"], attachments: []),
        MailMessage(id: "demo5", threadId: "demo5", subject: "Запись к стоматологу",
                    sender: "Clinique Dentaire <rdv@example.com>", recipients: "me@example.com", date: day(2025, 9, 30),
                    snippet: "Напоминаем о приёме 3 октября в 15:30",
                    body: "Напоминаем, что вы записаны к стоматологу на 3 октября в 15:30. Если не сможете прийти, предупредите заранее.",
                    labels: ["INBOX"], attachments: []),
    ]
}
