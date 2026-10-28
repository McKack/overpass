import SwiftUI

/// What the art search looks for: a 2:3 cover or a square icon.
enum ArtKind: Identifiable {
    case cover, icon
    var id: Self { self }
}

struct ArtResult: Identifiable, Hashable {
    let title: String
    let url: URL
    var id: URL { url }
}

/// A store whose public catalogue can be searched for art, a page at a time.
@MainActor
struct ArtSource: Identifiable {
    let name: String
    let kinds: Set<ArtKind>
    /// Results `offset..<offset+count` for a search.
    let search: (_ query: String, _ kind: ArtKind, _ offset: Int, _ count: Int) async -> [ArtResult]
    nonisolated var id: String { name }

    static let all: [ArtSource] = [steam, gog]

    /// Steam's store search, then the library capsules of the matches. Steam's own icons are only 32 px, so
    /// Steam is searched for covers only.
    static let steam = ArtSource(name: "Steam", kinds: [.cover]) { query, _, offset, count in
        var search = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        search.queryItems = [.init(name: "term", value: query), .init(name: "l", value: "english"), .init(name: "cc", value: "US")]
        guard let url = search.url, let items = await json(url)?["items"] as? [[String: Any]] else { return [] }
        let page = items.dropFirst(offset).prefix(count).compactMap { item -> (Int, String)? in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return (id, name)
        }
        guard !page.isEmpty else { return [] }
        let ids = page.map { #"{"appid":\#($0.0)}"# }.joined(separator: ",")
        var api = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1")!
        api.queryItems = [.init(name: "input_json", value: #"{"ids":[\#(ids)],"context":{"language":"english","country_code":"US","steam_realm":1},"data_request":{"include_assets":true}}"#)]
        guard let apiURL = api.url,
              let stored = (await json(apiURL)?["response"] as? [String: Any])?["store_items"] as? [[String: Any]] else { return [] }
        return page.compactMap { id, name in
            guard let assets = stored.first(where: { $0["appid"] as? Int == id })?["assets"] as? [String: Any],
                  let format = assets["asset_url_format"] as? String,
                  let file = (assets["library_capsule_2x"] ?? assets["library_capsule"]) as? String,
                  let url = URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/"
                                + format.replacingOccurrences(of: "${FILENAME}", with: file)) else { return nil }
            return ArtResult(title: name, url: url)
        }
    }

    /// GOG's catalogue: vertical covers come with the search; square icons need each game's own record.
    static let gog = ArtSource(name: "GOG", kinds: [.cover, .icon]) { query, kind, offset, count in
        // The catalogue pages by a fixed size, so ask for everything up to the end of this page and slice.
        var search = URLComponents(string: "https://catalog.gog.com/v1/catalog")!
        search.queryItems = [.init(name: "limit", value: "\(offset + count)"), .init(name: "query", value: "like:\(query)"),
                             .init(name: "order", value: "desc:score"), .init(name: "productType", value: "in:game,pack")]
        guard let url = search.url, let products = await json(url)?["products"] as? [[String: Any]] else { return [] }
        var results: [ArtResult] = []
        for product in products.dropFirst(offset).prefix(count) {
            guard let title = product["title"] as? String else { continue }
            switch kind {
            case .cover:
                if let cover = (product["coverVertical"] as? String).flatMap(URL.init(string:)) {
                    results.append(ArtResult(title: title, url: cover))
                }
            case .icon:
                guard let id = product["id"] as? String,
                      let game = URL(string: "https://api.gog.com/v2/games/\(id)?locale=en-US"),
                      let links = await json(game)?["_links"] as? [String: Any],
                      let href = (links["iconSquare"] as? [String: Any])?["href"] as? String,
                      let icon = URL(string: href) else { continue }
                results.append(ArtResult(title: title, url: icon))
            }
        }
        return results
    }

    private static func json(_ url: URL) async -> [String: Any]? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Searches the stores for a cover or icon, a few results per store with Load More under each; the picked
/// picture is downloaded to a temporary file and handed back.
struct ArtSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: ArtKind
    let pick: (URL) -> Void
    @State var query: String
    @State private var results: [String: [ArtResult]] = [:]
    @State private var loading: Set<String> = []
    @State private var exhausted: Set<String> = []
    /// How many of each store's matches have been asked for; some come back without art.
    @State private var offsets: [String: Int] = [:]
    @State private var downloading: URL?
    @State private var failed = false

    private static let pageSize = 3
    private var sources: [ArtSource] { ArtSource.all.filter { $0.kinds.contains(kind) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Game name", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(searchAll)
                Button("Search", action: searchAll).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(sources) { source in sourceSection(source) }
                }
                .padding()
            }
            Divider()
            HStack {
                if failed {
                    Label("Couldn't download that picture.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 560, height: 560)
        .task { searchAll() }
    }

    private func sourceSection(_ source: ArtSource) -> some View {
        let found = results[source.name] ?? []
        let tileWidth: CGFloat = kind == .cover ? 110 : 72
        return VStack(alignment: .leading, spacing: 10) {
            Text(source.name).font(.headline)
            if found.isEmpty && !loading.contains(source.name) {
                Text("Nothing found.").foregroundStyle(.secondary).font(.callout)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(found) { result in
                    Button { choose(result) } label: {
                        VStack(spacing: 4) {
                            AsyncImage(url: result.url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(.quaternary)
                            }
                            .frame(width: tileWidth, height: kind == .cover ? tileWidth * 1.5 : tileWidth)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay { if downloading == result.url { ProgressView() } }
                            Text(result.title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                .frame(width: tileWidth)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Use this picture")
                }
            }
            if loading.contains(source.name) {
                ProgressView().controlSize(.small)
            } else if !found.isEmpty && !exhausted.contains(source.name) {
                Button("Load More…") { load(source) }.controlSize(.small)
            }
        }
    }

    private func searchAll() {
        results = [:]
        exhausted = []
        offsets = [:]
        for source in sources { load(source) }
    }

    private func load(_ source: ArtSource) {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !loading.contains(source.name) else { return }
        loading.insert(source.name)
        let offset = offsets[source.name] ?? 0
        offsets[source.name] = offset + Self.pageSize
        Task {
            let page = await source.search(term, kind, offset, Self.pageSize)
            // A newer search replaced this one meanwhile.
            guard term == query.trimmingCharacters(in: .whitespaces) else { loading.remove(source.name); return }
            results[source.name, default: []] += page
            // A store may skip matches without art, so only an empty page means there's nothing more.
            if page.isEmpty { exhausted.insert(source.name) }
            loading.remove(source.name)
        }
    }

    private func choose(_ result: ArtResult) {
        downloading = result.url
        failed = false
        Task {
            defer { downloading = nil }
            guard let (data, response) = try? await URLSession.shared.data(from: result.url),
                  (response as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil else {
                failed = true
                return
            }
            let ext = result.url.pathExtension.lowercased() == "png" ? "png" : "jpg"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            guard (try? data.write(to: file)) != nil else { failed = true; return }
            pick(file)
            dismiss()
        }
    }
}
