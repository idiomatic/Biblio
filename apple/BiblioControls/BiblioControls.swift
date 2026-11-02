import AppIntents
import SwiftUI
import WidgetKit

@main
struct BiblioControls: WidgetBundle {
    var body: some Widget {
        LibraryCardControl()
    }
}

/// A Lock Screen and Control Center button that opens Biblio to the library card barcode.
struct LibraryCardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.rbrian.Biblio.LibraryCard") {
            ControlWidgetButton(action: ShowLibraryCardIntent()) {
                Label("Library Card", systemImage: "barcode")
            }
        }
        .displayName("Library Card")
        .description("Shows your library card barcode in Biblio.")
    }
}
