import SwiftUI

struct SearchView: View {
    @Bindable var session: WindowSession
    @State private var showAdvanced = false

    var body: some View {
        ItemListView(session: session, model: session.searchList,
                     emptyTitle: "No Results", emptySystemImage: "magnifyingglass") {
            #if os(iOS)
            SearchField(session: session)
                .listRowSeparator(.hidden)
            #endif
            if case .search(let q) = session.searchList.source, !q.isEmpty {
                FacetFilterBar(model: session.searchList, session: session, includeDetailedFacets: true)
                    .listRowSeparator(.hidden)
                if session.searchList.total > 0 {
                    Text("\(session.searchList.total.formatted()) results for “\(q.query)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .overlay {
            if case .search(let q) = session.searchList.source, q.isEmpty {
                ContentUnavailableView {
                    Label("Search \(session.library.shortName ?? "the Catalog")", systemImage: "magnifyingglass")
                } description: {
                    Text("Type in the search field to find books, movies, music and more.")
                } actions: {
                    Button("Advanced Search…") { showAdvanced = true }
                }
            }
        }
        .navigationTitle("Search")
        .toolbar {
            ToolbarItem {
                Button("Advanced Search", systemImage: "slider.horizontal.3") { showAdvanced = true }
                    .help("Advanced search")
            }
        }
        .sheet(isPresented: $showAdvanced) {
            AdvancedSearchView(library: session.library) { query, filters in
                session.searchText = query
                session.section = .search
                session.searchList.source = .search(SearchQuery(query: query, searchType: "bl", filters: filters))
                session.searchList.reload()
            }
        }
    }
}

/// Builds a field-qualified ("bl") query such as `title:(dune) AND contributor:(herbert)`.
struct AdvancedSearchView: View {
    var library: LibraryInfo
    var run: (String, [String: String]) -> Void

    struct Term: Identifiable {
        let id = UUID()
        var field = "anywhere"
        var text = ""
        var op = "AND"
    }

    static let fields: [(String, String)] = [
        ("anywhere", "Keyword"), ("title", "Title"), ("contributor", "Author"),
        ("subject", "Subject"), ("series", "Series"), ("genre", "Genre"), ("publisher", "Publisher"),
        ("isbn", "ISBN"), ("callnumber", "Call Number"),
    ]

    @Environment(\.dismiss) private var dismiss
    @State private var terms = [Term(), Term(field: "title"), Term(field: "contributor")]
    @State private var format: String?
    @State private var audience: String?
    @State private var language: String?
    @State private var fromYear = ""
    @State private var toYear = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Search For") {
                    ForEach($terms) { $term in
                        HStack {
                            if term.id != terms.first?.id {
                                Picker("", selection: $term.op) {
                                    Text("and").tag("AND")
                                    Text("or").tag("OR")
                                    Text("not").tag("NOT")
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                            Picker("", selection: $term.field) {
                                ForEach(Self.fields, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            TextField("Terms", text: $term.text)
                                .autocorrectionDisabled()
                        }
                    }
                    .onDelete { terms.remove(atOffsets: $0) }
                    Button("Add Term", systemImage: "plus.circle") { terms.append(Term()) }
                }
                Section("Limit To") {
                    Picker("Format", selection: $format) {
                        Text("Any").tag(String?.none)
                        ForEach(LibraryInfo.fallbackFormatNames.keys.sorted { library.formatName($0) < library.formatName($1) }, id: \.self) {
                            Text(library.formatName($0)).tag(Optional($0))
                        }
                        Text(library.formatName("UK")).tag(Optional("UK"))
                    }
                    Picker("Audience", selection: $audience) {
                        Text("Any").tag(String?.none)
                        Text(library.label("AUDIENCE.adult") ?? "Adult").tag(Optional("adult"))
                        Text(library.label("AUDIENCE.teen") ?? "Teen").tag(Optional("teen"))
                        Text(library.label("AUDIENCE.juvenile") ?? "Children").tag(Optional("juvenile"))
                    }
                    Picker("Language", selection: $language) {
                        Text("Any").tag(String?.none)
                        ForEach(["eng", "spa", "chi", "fre", "ger", "jpn", "kor", "rus", "vie", "ara", "hin", "por", "tgl", "ita"], id: \.self) {
                            Text(library.label("LANGUAGE.\($0)") ?? $0).tag(Optional($0))
                        }
                    }
                    LabeledContent("Published") {
                        HStack {
                            TextField("From", text: $fromYear).frame(maxWidth: 80)
                            Text("–")
                            TextField("To", text: $toYear).frame(maxWidth: 80)
                        }
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    }
                }
                Section {
                    Text(query.isEmpty ? "Enter at least one term." : query)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Query")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Advanced Search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search") {
                        run(query, filters)
                        dismiss()
                    }
                    .disabled(query.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .macMinFrame(width: 520, height: 520)
    }

    private var query: String {
        var parts: [String] = []
        for term in terms {
            let text = term.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let clause = "\(term.field):(\(text))"
            parts.append(parts.isEmpty ? (term.op == "NOT" ? "NOT \(clause)" : clause) : "\(term.op) \(clause)")
        }
        let from = Int(fromYear), to = Int(toYear)
        if from != nil || to != nil, !parts.isEmpty {
            parts.append("AND pubyear:[\(from.map(String.init) ?? "*") TO \(to.map(String.init) ?? "*")]")
        }
        return parts.joined(separator: " ")
    }

    private var filters: [String: String] {
        var f: [String: String] = [:]
        if let format { f["f_FORMAT"] = format }
        if let audience { f["f_AUDIENCE"] = audience }
        if let language { f["f_LANGUAGE"] = language }
        return f
    }
}

/// Explore New Titles: Just Arrived / On Order tabs and the Filter by picker over the full "View All" list.
/// Explore New Titles: the "View All New Titles" list, with Just Arrived / On Order as a filter.
struct NewTitlesView: View {
    @Bindable var session: WindowSession

    private var model: ItemListModel { session.newTitlesList }

    private var onOrder: Bool {
        if case .search(let q) = model.source { return q.filters["f_on_order"] == "true" }
        return false
    }

    var body: some View {
        ItemListView(session: session, model: model,
                     emptyTitle: "No New Titles", emptySystemImage: "sparkles") {
            FacetFilterBar(model: model, session: session) {
                FilterChip(title: "Arrival", selection: onOrder ? "On Order" : "Just Arrived", isActive: true) {
                    Picker("Arrival", selection: Binding(get: { onOrder },
                                                         set: { model.setSource(.search(.newTitles(onOrder: $0))) })) {
                        Label("Just Arrived", systemImage: "sparkles").tag(false)
                        Label("On Order", systemImage: "shippingbox").tag(true)
                    }
                    .pickerStyle(.inline)
                }
            }
            .listRowSeparator(.hidden)
        }
        .navigationTitle(onOrder ? "New Titles · On Order" : "New Titles")
    }
}

/// A row of filter menus over a catalog search's facets (format, audience, …).
struct FacetFilterBar<Leading: View>: View {
    var model: ItemListModel
    @Bindable var session: WindowSession
    var includeDetailedFacets = false
    @ViewBuilder var leading: () -> Leading

    private var library: LibraryInfo { session.library }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Filter by")
                leading()
                facetMenu("FORMAT", title: "Format") { library.formatName($0) }
                if includeDetailedFacets {
                    facetMenu("STATUS", title: "Available At") { availabilityName($0) }
                }
                facetMenu("AUDIENCE", title: "Audience") { library.label("AUDIENCE.\($0.lowercased())") ?? $0.prettified }
                facetMenu("FICTION_TYPE", title: "Content") { library.label("FICTION_TYPE.\($0.lowercased())") ?? $0.prettified }
                facetMenu("LANGUAGE", title: "Language") { library.label("LANGUAGE.\($0)") ?? $0 }
                if includeDetailedFacets {
                    facetMenu("PUBLISHED_DATE", title: "Published") { $0 }
                    facetMenu("NEWLY_ACQUIRED", title: "Added") { $0.replacingOccurrences(of: "PAST_", with: "Past ").prettified }
                }
                if !model.facetFilters.isEmpty {
                    Button("Clear") {
                        for key in model.facetFilters.keys { model.setFacet(key, nil) }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func availabilityName(_ value: String) -> String {
        switch value {
        case "_online_": "Online"
        case "_physical_": "Any Location"
        default: session.locations.first { $0.id == value }?.name ?? value
        }
    }

    @ViewBuilder
    private func facetMenu(_ id: String, title: String, name: @escaping (String) -> String) -> some View {
        let values = model.facets.first { $0.id == id }?.values ?? []
        let selected = model.facetFilters[id]
        if !values.isEmpty || selected != nil {
            FilterChip(title: title, selection: selected.map(name), isActive: selected != nil) {
                Picker(title, selection: Binding(get: { selected }, set: { model.setFacet(id, $0) })) {
                    Text("Any \(title)").tag(String?.none)
                    ForEach(values, id: \.value) { v in
                        Text("\(name(v.value)) (\(v.count.formatted()))").tag(Optional(v.value))
                    }
                }
                .pickerStyle(.inline)
            }
        }
    }
}

extension FacetFilterBar where Leading == EmptyView {
    init(model: ItemListModel, session: WindowSession, includeDetailedFacets: Bool = false) {
        self.init(model: model, session: session, includeDetailedFacets: includeDetailedFacets) { EmptyView() }
    }
}

/// A compact bordered menu button showing a filter's current choice.
struct FilterChip<Content: View>: View {
    var title: String
    var selection: String?
    var isActive: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Text(selection ?? title)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isActive ? .accentColor : .secondary)
        .fixedSize()
        .accessibilityLabel(selection.map { "\(title): \($0)" } ?? title)
    }
}

/// Ready / Not Ready / On Order filter for the holds list: a segmented control whose segments
/// carry count badges (a system segmented Picker can only show plain text).
struct HoldFilterBar: View {
    var model: ItemListModel

    @Namespace private var selectionSpace

    var body: some View {
        HStack(spacing: 2) {
            segment(nil, title: "All", count: nil)
            ForEach(ItemListModel.HoldFilter.allCases) { f in
                segment(f, title: f.title, count: model.holdCount(f))
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
    }

    private func segment(_ filter: ItemListModel.HoldFilter?, title: String, count: Int?) -> some View {
        let selected = model.holdFilter == filter
        return Button {
            withAnimation(.snappy(duration: 0.2)) { model.setHoldFilter(filter) }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                if let count, count > 0 {
                    Text(count, format: .number)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((selected ? Color.accentColor : Color.secondary).opacity(0.16), in: Capsule())
                }
            }
            .fixedSize()   // segments share leftover width, never truncating a label
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct BorrowingListView: View {
    @Bindable var session: WindowSession
    var section: AppSection

    @State private var dropTargeted = false

    var body: some View {
        let model = session.list(for: section)!
        ItemListView(session: session, model: model,
                     emptyTitle: emptyTitle, emptySystemImage: section.systemImage) {
            if section == .holds {
                HoldFilterBar(model: model)
                    .listRowSeparator(.hidden)
            }
        }
        .navigationTitle(section.title)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: section == .holds ? [.biblioItem] : [],
                isTargeted: Binding(get: { dropTargeted }, set: { dropTargeted = section == .holds && $0 })) { providers in
            BibTransfer.load(from: providers) { item in Task { await session.placeHold(item) } }
        }
    }

    private var emptyTitle: String {
        switch section {
        case .holds: "No Holds"
        case .checkouts: "Nothing Checked Out"
        default: "No Borrowing History"
        }
    }
}
