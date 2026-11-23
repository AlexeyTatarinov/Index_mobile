// SPDX-License-Identifier: GPL-3.0-or-later
//
// CI screenshot mode: `-docsDemo YES` writes a few sample documents (Russian and
// English, text and PDF) into the app's own Documents folder, indexes them, and runs
// `-autoQuery` against them. Lets the simulator show document search end to end.

import Foundation
import UIKit

enum DocumentDemo {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "docsDemo") }

    @MainActor
    static func run(engine: DocumentEngine) async {
        guard isEnabled else { return }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Образцы", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in samples {
            try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        writePDF(to: folder.appendingPathComponent("Договор аренды.pdf"))

        if !engine.folders.contains(where: { $0.name == folder.lastPathComponent }) {
            engine.addFolder(url: folder)
        }
        // addFolder starts indexing; wait for it.
        for _ in 0..<600 where engine.isIndexing || engine.stats.chunks == 0 {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if let query = UserDefaults.standard.string(forKey: "autoQuery"), !query.isEmpty {
            await engine.search(query)
        }
    }

    private static let samples: [(String, String)] = [
        ("Налоговый вычет.txt", """
        Имущественный налоговый вычет при покупке квартиры.
        Чтобы вернуть 13% от стоимости жилья, подайте декларацию 3-НДФЛ в налоговую инспекцию. \
        Понадобятся: договор купли-продажи, акт приёма-передачи, выписка из ЕГРН, платёжные документы \
        и справка 2-НДФЛ с работы. Максимальная сумма вычета — 2 млн рублей.
        """),
        ("Рецепт борща.md", """
        # Борщ

        Свёклу натереть и потушить с томатной пастой. Капусту нашинковать, картофель нарезать кубиками. \
        Варить на говяжьем бульоне 40 минут, в конце добавить чеснок и зелень. Подавать со сметаной.
        """),
        ("Отпуск в Италии.txt", """
        План поездки: Рим — 3 дня, Флоренция — 2 дня, Венеция — 2 дня. \
        Билеты на поезд Trenitalia купить заранее. Страховка для визы Шенген оформлена до 15 августа.
        """),
        ("Car insurance.txt", """
        Vehicle insurance policy renewal. The comprehensive coverage includes theft, fire and collision. \
        Annual premium is due on March 1st. Contact the agent to update the driver list.
        """),
    ]

    private static func writePDF(to url: URL) {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let text = """
        ДОГОВОР АРЕНДЫ КВАРТИРЫ № 15
        г. Москва, 3 марта 2024 г.

        Арендодатель передаёт Арендатору во временное пользование квартиру по адресу: \
        ул. Ленина, д. 10, кв. 25. Ежемесячная арендная плата составляет 60 000 рублей и вносится \
        до 5 числа каждого месяца. Залог — одна месячная плата. Срок аренды — 11 месяцев.
        """
        try? renderer.writePDF(to: url) { context in
            context.beginPage()
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            (text as NSString).draw(
                in: CGRect(x: 50, y: 60, width: 495, height: 700),
                withAttributes: [.font: UIFont.systemFont(ofSize: 14), .paragraphStyle: style]
            )
        }
    }
}
