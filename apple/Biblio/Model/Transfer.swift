import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations).
    nonisolated static let biblioItem = UTType(exportedAs: "com.rbrian.biblio.item")
}

/// What is dragged out of an item's detail pane. Dropped on Holds it places a hold;
/// dropped on any window's search field its plain-text form ("title author") is searched.
nonisolated struct BibTransfer: Codable, Transferable, Sendable {
    /// Loads dropped items from item providers (`onDrop`), which works from other windows and
    /// inside AppKit-backed sidebars where `dropDestination` on a row may not fire.
    static func load(from providers: [NSItemProvider], into handler: @escaping @MainActor (BibTransfer) -> Void) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.biblioItem.identifier) }
        for provider in matching {
            _ = provider.loadTransferable(type: BibTransfer.self) { result in
                if case .success(let item) = result {
                    Task { @MainActor in handler(item) }
                }
            }
        }
        return !matching.isEmpty
    }

    var subdomain: String
    var bib: Bib

    var title: String { bib.title }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .biblioItem)
        ProxyRepresentation(exporting: \.bib.searchText)
    }
}
