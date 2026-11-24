// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mail uses the shared multilingual-e5-small embedder from the documents module.

import Foundation

extension TextEmbedder: MailTextEmbedding {
    var modelName: String { Self.modelName }
}

extension MailEmbedderProvider {
    static func installDefault() {
        if make == nil { make = { try TextEmbedder.shared() } }
    }
}
