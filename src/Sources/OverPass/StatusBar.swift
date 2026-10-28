import SwiftUI

/// What the status bar at the bottom of the main window says, set by the page on show ("Steam · 2 titles").
struct StatusTextKey: PreferenceKey {
    static let defaultValue = ""
    static func reduce(value: inout String, nextValue: () -> String) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

extension View {
    func statusText(_ text: String) -> some View { preference(key: StatusTextKey.self, value: text) }
}

private struct SearchTextKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// The toolbar's search text; each page filters what it shows by it.
    var searchText: String {
        get { self[SearchTextKey.self] }
        set { self[SearchTextKey.self] = newValue }
    }
}

/// "1 title", "6 titles".
func titleCount(_ count: Int) -> String { count == 1 ? "1 title" : "\(count) titles" }

/// The bar along the bottom of the main window, as in Finder: the page's status in the middle and, on library
/// pages, a slider for the size of the current layout on the right.
struct StatusBar: View {
    let text: String
    let showsSize: Bool
    @AppStorage(ViewOptions.layoutKey) private var layout: LibraryLayout = .grid

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ZStack {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 130)
                if showsSize {
                    HStack {
                        Spacer()
                        LayoutSizeSlider(layout: layout).id(layout)
                    }
                    .padding(.horizontal, 14)
                }
            }
            .frame(height: 28)
        }
    }
}

/// One layout's size; a view per layout so each reads and writes its own setting.
private struct LayoutSizeSlider: View {
    let layout: LibraryLayout
    @AppStorage private var size: Double

    init(layout: LibraryLayout) {
        self.layout = layout
        _size = AppStorage(wrappedValue: layout.defaultSize, layout.sizeKey)
    }

    var body: some View {
        Slider(value: $size, in: layout.sizeRange)
            .controlSize(.mini)
            .frame(width: 100)
            .help(layout == .covers ? "Cover size" : "Icon size")
    }
}

/// The toolbar's search field, as in Finder: a field when there's room, otherwise a button that opens one.
/// Our own item rather than `.searchable`, which macOS always puts at the end of the toolbar.
struct ToolbarSearch: View {
    @Binding var text: String
    let compact: Bool
    /// "Search GOG": names the page being searched.
    var prompt = "Search"
    @State private var expanded = false

    var body: some View {
        if compact && !expanded && text.isEmpty {
            Button { expanded = true } label: { Label(prompt, systemImage: "magnifyingglass") }
                .help(prompt)
        } else {
            SearchField(text: $text, prompt: prompt, focusOnAppear: compact) { expanded = false }
                .frame(width: compact ? 140 : 200)
        }
    }
}

private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt = "Search"
    var focusOnAppear = false
    /// Called when editing ends with the field empty, so a compact search folds back into its button.
    var endedEmpty: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        if focusOnAppear { DispatchQueue.main.async { field.window?.makeFirstResponder(field) } }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt { field.placeholderString = prompt }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        init(parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSSearchField { parent.text = field.stringValue }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            if parent.text.isEmpty { parent.endedEmpty() }
        }
    }
}
