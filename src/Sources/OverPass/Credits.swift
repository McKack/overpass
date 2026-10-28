import SwiftUI

/// The About window: the app, its version, and buttons for the credits and for supporting OverPass.
struct AboutView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("OverPass").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Version \(AppUpdate.currentVersion)").foregroundStyle(.secondary)
            Text("Windows games and apps on your Mac, built on Wine and many other open-source projects.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(width: 280)
                .padding(.top, 4)
            HStack(spacing: 10) {
                Button("Credits") { openWindow(id: "credits") }
                Button {
                    NSWorkspace.shared.open(Credits.supportURL)
                } label: {
                    Label("Support OverPass", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 10)
        }
        .padding(28)
        .frame(width: 360)
    }
}

/// CREDITS.md, shipped in the app and shown the way it reads on GitHub: one source for both.
enum Credits {
    static let supportURL = URL(string: "https://ko-fi.com/arctim")!

    struct Section: Identifiable {
        let title: String
        var paragraphs: [String] = []
        var entries: [String] = []
        var id: String { title }
    }

    /// The file's sections: its intro (titled after the file's heading), then each "## " section, with its
    /// list items and its paragraphs, both still in Markdown.
    static func sections() -> [Section] {
        guard let url = Bundle.main.url(forResource: "CREDITS", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var sections: [Section] = []
        var paragraph: [String] = []
        var item: [String] = []
        func flush() {
            guard !sections.isEmpty else { return }
            if !item.isEmpty { sections[sections.count - 1].entries.append(item.joined(separator: " ")); item = [] }
            if !paragraph.isEmpty { sections[sections.count - 1].paragraphs.append(paragraph.joined(separator: " ")); paragraph = [] }
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                sections.append(Section(title: String(line.dropFirst(2))))
            } else if line.hasPrefix("## ") {
                flush()
                sections.append(Section(title: String(line.dropFirst(3))))
            } else if line.hasPrefix("- ") {
                flush()
                item = [String(line.dropFirst(2))]
            } else if line.isEmpty {
                flush()
            } else if !item.isEmpty {
                item.append(line)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return sections
    }
}

struct CreditsView: View {
    private let sections = Credits.sections()

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.paragraphs, id: \.self) { text in
                        Text(markdown(text)).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(section.entries, id: \.self) { entry($0) }
                }
            }
        }
        .overlay {
            if sections.isEmpty { ContentUnavailableView("No Credits File", systemImage: "doc.questionmark") }
        }
    }

    /// One credit as its full sentence, the project's name in bold as a link, as it reads on GitHub.
    private func entry(_ text: String) -> some View {
        Text(markdown(text))
            .lineSpacing(2)
            .padding(.vertical, 3)
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
