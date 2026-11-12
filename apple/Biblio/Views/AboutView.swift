import SwiftUI

/// What the About box says, beyond the app's name and version.
enum About {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    static let credits = """
        Biblio was made by people working together with AI assistants. \
        They shared the work of planning, building and testing the app.
        """
    static let independence = "Biblio is an independent app. It isn’t made by BiblioCommons or by your library."

    #if os(macOS)
    /// The standard About panel, with the credits under the version.
    static func showPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: "\(credits)\n\n\(independence)", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: text])
    }
    #endif
}

#if os(macOS)
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Biblio") { MainActor.assumeIsolated { About.showPanel() } }
        }
        CommandGroup(after: .help) {
            Divider()
            Button("Copy Diagnostic Log") { ThrottleLog.copyReport() }
        }
    }
}
#endif

/// The About sheet on iOS and iPadOS, opened from the version at the foot of the sidebar.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image("AboutIcon")
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(spacing: 4) {
                        Text("Biblio").font(.title2.bold())
                        Text("Version \(About.version)").foregroundStyle(.secondary)
                    }
                    Text(About.credits)
                    Text(About.independence).foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        Button(copied ? "Copied" : "Copy Diagnostic Log", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            ThrottleLog.copyReport()
                            copied = true
                        }
                        .buttonStyle(.bordered)
                        Text("A list of the times a library’s server limited or failed a request. It names no account, and nothing is sent unless you share it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("About")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.fraction(0.85), .large])
    }
}
