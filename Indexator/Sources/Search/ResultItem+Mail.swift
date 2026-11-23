// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension ResultItem {
    init(mail hit: MailHit) {
        self.init(
            id: hit.id,
            kind: .mail,
            title: hit.subject.isEmpty ? "(без темы)" : hit.subject,
            snippet: hit.snippet,
            date: hit.date,
            score: hit.score,
            textMatch: hit.textMatch,
            sender: hit.sender
        )
    }
}
