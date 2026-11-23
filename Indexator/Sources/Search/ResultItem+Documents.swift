// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension ResultItem {
    init(document hit: DocumentHit) {
        let folder = (hit.relativePath as NSString).deletingLastPathComponent
        self.init(
            id: hit.id,
            kind: .document,
            title: hit.title,
            snippet: hit.snippet,
            date: hit.date,
            score: hit.score,
            textMatch: hit.textMatch,
            fileURL: hit.fileURL,
            contentType: hit.contentType,
            sender: folder.isEmpty ? hit.folderName : "\(hit.folderName)/\(folder)",
            page: hit.page
        )
    }
}
