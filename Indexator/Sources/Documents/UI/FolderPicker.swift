// SPDX-License-Identifier: GPL-3.0-or-later
//
// UIKit folder picker. SwiftUI's .fileImporter cannot choose where the picker opens,
// and on some phones it lands inside "On My iPhone" with no obvious way out. This one
// can start right in iCloud Drive (or anywhere else) via directoryURL.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum PickerStart: Identifiable {
    case iCloudDrive, onMyPhone, files
    var id: Self { self }

    /// Where the picker opens. iCloud Drive's local root is the same on every iPhone;
    /// "On My iPhone" has no public path, so it opens at the picker's own start.
    var directoryURL: URL? {
        switch self {
        case .iCloudDrive:
            return URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        case .onMyPhone, .files:
            return nil
        }
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let start: PickerStart
    var contentTypes: [UTType] = [.folder]
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        if let url = start.directoryURL {
            picker.directoryURL = url
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
